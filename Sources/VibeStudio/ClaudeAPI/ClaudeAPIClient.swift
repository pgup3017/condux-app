import Foundation

/// Anthropic Messages API(`POST /v1/messages`, SSE 스트리밍)를 사용자 자신의 API 키로 직접 호출합니다.
/// Swift 공식 SDK 가 없어 원시 HTTP 로 구현합니다. 구독 로그인과는 완전히 별개의 경로이며,
/// 구독 한도가 끝나도 이 경로로 자동 전환하지 않습니다.
///
/// 참고: https://platform.claude.com/docs/en/api/messages (anthropic-version 2026-10-21)

// MARK: 요금표 (추정용)

/// 1M 토큰당 달러. 2026-10 기준 공식 API 요율. 실제 청구와 다를 수 있는 추정치로만 씁니다.
struct ClaudePricing: Equatable {
    var input: Double
    var output: Double
    var cacheRead: Double
    var cacheWrite: Double
    var known: Bool = true
    /// 웹 검색 1회 요금. Anthropic·OpenAI 모두 공식 요금이 1,000회당 $10 입니다. 결과 토큰은 입력 요금으로 따로 잡힙니다.
    static let webSearchUSD = 0.01

    static let table: [String: ClaudePricing] = [
        "claude-fable-5-1": ClaudePricing(input: 10, output: 50, cacheRead: 0.25, cacheWrite: 12.5),
        "claude-opus-5-5": ClaudePricing(input: 4, output: 20, cacheRead: 0.20, cacheWrite: 5),
        "claude-sonnet-5-5": ClaudePricing(input: 2, output: 10, cacheRead: 0.20, cacheWrite: 2.5),
        "claude-haiku-5-5": ClaudePricing(input: 0.10, output: 0.50, cacheRead: 0.01, cacheWrite: 0.125),
    ]

    /// 모르는 모델은 가장 비싼 요율로 보수적으로 추정합니다.
    static func forModel(_ model: String) -> ClaudePricing {
        if let exact = table[model] { return exact }
        var fallback = table["claude-fable-5-1"]!
        fallback.known = false
        return fallback
    }

    func estimate(_ usage: ClaudeAPIUsage) -> Double {
        (Double(usage.inputTokens) * input
         + Double(usage.outputTokens) * output
         + Double(usage.cacheReadTokens) * cacheRead
         + Double(usage.cacheWriteTokens) * cacheWrite) / 1_000_000
            + Double(usage.webSearchRequests) * ClaudePricing.webSearchUSD
    }
}

struct ClaudeAPIUsage: Equatable {
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheWriteTokens = 0
    var webSearchRequests = 0

    mutating func merge(_ json: JSONValue?) {
        guard let json else { return }
        if let v = json["input_tokens"]?.intValue { inputTokens = v }
        if let v = json["output_tokens"]?.intValue { outputTokens = v }
        if let v = json["cache_read_input_tokens"]?.intValue { cacheReadTokens = v }
        if let v = json["cache_creation_input_tokens"]?.intValue { cacheWriteTokens = v }
        if let v = json["server_tool_use"]?["web_search_requests"]?.intValue { webSearchRequests = v }
    }
}

// MARK: 이벤트

enum ClaudeAPIEvent {
    /// message_start: 실제로 답한 모델과 입력 토큰
    case started(model: String, messageID: String)
    case blockStarted(index: Int, type: String)
    /// 글·생각이 아닌 블록(웹 검색 등)의 원본. 다음 턴에 받은 그대로 돌려보내야 합니다.
    case rawBlock(index: Int, block: JSONValue)
    case inputDelta(index: Int, partialJSON: String)
    case citationDelta(index: Int, citation: JSONValue)
    /// 답변이 인용한 출처
    case source(title: String, url: String)
    /// 서버가 웹을 쓰는 중. OpenAI 처럼 블록으로 오지 않는 연결에서 씁니다.
    case webActivity(key: String, name: String, detail: String)
    case textDelta(index: Int, text: String)
    case thinkingDelta(index: Int, text: String)
    case signatureDelta(index: Int, signature: String)
    case blockStopped(index: Int)
    /// message_delta: 종료 이유와 출력 토큰
    case finished(stopReason: String, stopDetails: JSONValue?)
    case usage(ClaudeAPIUsage)
    case log(String)
}

enum ClaudeAPIError: LocalizedError, Equatable {
    case missingKey
    case http(status: Int, type: String, message: String)
    case malformed(String)
    case transport(code: Int?)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingKey: return "Claude API 키가 설정되어 있지 않습니다."
        case .http(let status, let type, let message):
            switch status {
            case 401: return "API 키가 유효하지 않습니다 (401). 설정에서 키를 다시 확인해 주세요."
            case 402: return "API 잔액/결제 문제입니다 (402): \(message)"
            case 400 where type == "billing_error": return "API 잔액/결제 문제입니다 (400): \(message)"
            case 429: return "API 요청 한도에 걸렸습니다 (429). 잠시 후 다시 시도해 주세요."
            case 529: return "API 서버가 혼잡합니다 (529). 잠시 후 다시 시도해 주세요."
            default: return "API 오류 \(status) \(type): \(message)"
            }
        case .malformed(let what): return "API 응답을 해석할 수 없습니다: \(what.prefix(200))"
        case .transport(let code):
            return "API 연결에 실패했습니다. 네트워크 상태를 확인한 뒤 다시 시도해 주세요."
                + (code.map { " (오류 코드 \($0))" } ?? "")
        case .cancelled: return "요청이 중단되었습니다."
        }
    }
}

/// 진단용 문자열만 가립니다. 인증 헤더와 대화 본문 자체는 변경하지 않습니다.
enum APIDiagnostics {
    static func redacted(_ text: String, apiKey: String) -> String {
        var result = text
        // 자르기 전에 실제 요청 키를 먼저 가려야 키 일부가 로그에 남지 않습니다.
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { result = result.replacingOccurrences(of: key, with: "[가림]") }
        for (pattern, replacement) in [
            (#"(?i)(["']?(?:authorization|x-api-key)["']?\s*[:=]\s*)(?:"[^"\r\n]*"|'[^'\r\n]*'|[^\r\n,;}]+)"#, "$1[가림]"),
            (#"(?i)\bBearer[ \t]+[^\s"',;}]+"#, "[가림]"),
            (#"(?i)\bsk-[a-z0-9_-]+"#, "[가림]"),
        ] {
            result = result.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return result
    }

    static func safeError(_ error: Error, apiKey: String) -> ClaudeAPIError {
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled ? .cancelled : .transport(code: urlError.code.rawValue)
        }
        guard let apiError = error as? ClaudeAPIError else { return .transport(code: nil) }
        switch apiError {
        case .http(let status, let type, let message):
            return .http(status: status, type: redacted(type, apiKey: apiKey), message: redacted(message, apiKey: apiKey))
        case .malformed(let message): return .malformed(redacted(message, apiKey: apiKey))
        case .missingKey, .cancelled, .transport: return apiError
        }
    }
}

// MARK: 전송 계층 (테스트에서 바꿔 끼움)

protocol ClaudeAPITransport {
    /// 요청을 보내고 (HTTP 상태, 응답 본문 줄 스트림)을 돌려줍니다.
    func send(_ request: URLRequest) async throws -> (status: Int, lines: AsyncThrowingStream<String, Error>)
}

struct URLSessionTransport: ClaudeAPITransport {
    var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 3600
        return URLSession(configuration: config)
    }()

    func send(_ request: URLRequest) async throws -> (status: Int, lines: AsyncThrowingStream<String, Error>) {
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let stream = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (status, stream)
    }
}

// MARK: 요청

struct ClaudeAPIRequest {
    var model: String
    var system: String
    /// Messages API 형식 그대로. thinking 블록은 받은 그대로 돌려보내야 하므로 JSONValue 로 보관합니다.
    var messages: [JSONValue]
    var maxTokens: Int
    var effort: String = ""
    /// 안전 정책 거부 시 서버가 다른 모델로 이어서 답하게 할지. 요율이 달라질 수 있어 기본은 끕니다.
    var serverFallback = false
    /// 서버에서 실행되는 도구(웹 검색 등). 비어 있으면 보내지 않습니다.
    var tools: [JSONValue] = []

    /// 모든 현재 모델이 받는 기본판입니다. 최신판의 결과 걸러내기는 코드 실행 블록이 섞여 대화 기록이 복잡해져서 쓰지 않습니다.
    static let webTools: [JSONValue] = [
        ["type": "web_search_20250305", "name": "web_search", "max_uses": 5],
        ["type": "web_fetch_20250910", "name": "web_fetch", "max_uses": 3, "max_content_tokens": 20_000],
    ]

    static let apiVersion = "2026-10-21"
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    func body() -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "max_tokens": .number(Double(maxTokens)),
            "stream": true,
            "messages": .array(messages),
            // 현재 세대(Opus 5.5·Sonnet 5.5·Haiku 5.5·Fable 5.1) 공통: 적응형 사고 + 요약 표시
            "thinking": ["type": "adaptive", "display": "summarized"],
        ]
        if !system.isEmpty { body["system"] = .string(system) }
        if !effort.isEmpty { body["output_config"] = ["effort": .string(effort)] }
        if serverFallback { body["fallbacks"] = "default" }
        if !tools.isEmpty { body["tools"] = .array(tools) }
        return .object(body)
    }

    func urlRequest(apiKey: String) throws -> URLRequest {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        if serverFallback { request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta") }
        request.httpBody = Data(try body().compactJSON().utf8)
        return request
    }
}

// MARK: 클라이언트

final class ClaudeAPIClient {
    private let transport: ClaudeAPITransport

    init(transport: ClaudeAPITransport = URLSessionTransport()) {
        self.transport = transport
    }

    /// 한 턴을 스트리밍합니다. 이벤트는 호출한 Task 안에서 순서대로 전달됩니다. Task 취소로 중단합니다.
    func stream(_ request: ClaudeAPIRequest, apiKey: String, onEvent: @escaping @MainActor (ClaudeAPIEvent) -> Void) async throws {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ClaudeAPIError.missingKey }
        do {
            let urlRequest = try request.urlRequest(apiKey: key)
            await onEvent(.log(APIDiagnostics.redacted("→ POST /v1/messages model=\(request.model) max_tokens=\(request.maxTokens) messages=\(request.messages.count)", apiKey: key)))

            let (status, lines) = try await transport.send(urlRequest)
            if status < 200 || status >= 300 {
                var text = ""
                for try await line in lines { text += line }
                let json = try? JSONValue.parse(text)
                throw ClaudeAPIError.http(status: status,
                                          type: json?["error"]?["type"]?.stringValue ?? "unknown",
                                          message: json?["error"]?["message"]?.stringValue ?? String(APIDiagnostics.redacted(text, apiKey: key).prefix(300)))
            }

            var eventName = ""
            var usage = ClaudeAPIUsage()
            for try await rawLine in lines {
                try Task.checkCancellation()
                let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
                if line.isEmpty { eventName = ""; continue }
                if line.hasPrefix("event:") { eventName = line.dropFirst(6).trimmingCharacters(in: .whitespaces); continue }
                guard line.hasPrefix("data:") else { continue }
                let payloadText = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard let payload = try? JSONValue.parse(payloadText) else {
                    await onEvent(.log("! API 응답을 해석할 수 없습니다."))
                    continue
                }
                let type = payload["type"]?.stringValue ?? eventName
                switch type {
                case "message_start":
                    let message = payload["message"] ?? .null
                    usage.merge(message["usage"])
                    await onEvent(.usage(usage))
                    await onEvent(.started(model: message["model"]?.stringValue ?? request.model,
                                     messageID: message["id"]?.stringValue ?? ""))
                case "content_block_start":
                    let index = payload["index"]?.intValue ?? 0
                    let block = payload["content_block"] ?? .null
                    let blockType = block["type"]?.stringValue ?? "unknown"
                    await onEvent(.blockStarted(index: index, type: blockType))
                    if blockType != "text", blockType != "thinking" { await onEvent(.rawBlock(index: index, block: block)) }
                case "content_block_delta":
                    let index = payload["index"]?.intValue ?? 0
                    let delta = payload["delta"] ?? .null
                    switch delta["type"]?.stringValue {
                    case "text_delta": await onEvent(.textDelta(index: index, text: delta["text"]?.stringValue ?? ""))
                    case "thinking_delta": await onEvent(.thinkingDelta(index: index, text: delta["thinking"]?.stringValue ?? ""))
                    case "signature_delta": await onEvent(.signatureDelta(index: index, signature: delta["signature"]?.stringValue ?? ""))
                    case "input_json_delta": await onEvent(.inputDelta(index: index, partialJSON: delta["partial_json"]?.stringValue ?? ""))
                    case "citations_delta":
                        let citation = delta["citation"] ?? .null
                        await onEvent(.citationDelta(index: index, citation: citation))
                        if let url = citation["url"]?.stringValue {
                            await onEvent(.source(title: citation["title"]?.stringValue ?? url, url: url))
                        }
                    default: await onEvent(.log("← 알 수 없는 delta 유형입니다."))
                    }
                case "content_block_stop":
                    await onEvent(.blockStopped(index: payload["index"]?.intValue ?? 0))
                case "message_delta":
                    usage.merge(payload["usage"])
                    await onEvent(.usage(usage))
                    if let stop = payload["delta"]?["stop_reason"]?.stringValue {
                        await onEvent(.finished(stopReason: stop, stopDetails: payload["delta"]?["stop_details"]))
                    }
                case "message_stop", "ping":
                    break
                case "error":
                    let error = payload["error"] ?? .null
                    throw ClaudeAPIError.http(status: 200, type: error["type"]?.stringValue ?? "stream_error",
                                              message: error["message"]?.stringValue ?? "스트림 오류")
                default:
                    await onEvent(.log("← 알 수 없는 이벤트 유형입니다."))
                }
            }
            // AsyncThrowingStream 은 Task 가 취소되면 오류 없이 조용히 끝나므로 여기서 취소를 분명히 합니다.
            try Task.checkCancellation()
        } catch {
            throw APIDiagnostics.safeError(error, apiKey: key)
        }
    }
}

// MARK: 답변 블록 조립

/// 스트리밍으로 받은 블록을 Messages API 형식의 assistant content 로 다시 조립합니다.
/// thinking 블록은 서명까지 그대로 보관해야 다음 턴에 돌려보낼 수 있습니다.
struct ClaudeAPIBlockAssembler {
    private struct Block {
        var type: String; var text = ""; var signature = ""; var completed = false
        var raw: JSONValue?; var partialInput = ""; var citations: [JSONValue] = []
    }
    private var blocks: [Int: Block] = [:]

    mutating func apply(_ event: ClaudeAPIEvent) {
        switch event {
        case .blockStarted(let index, let type): blocks[index] = Block(type: type)
        case .textDelta(let index, let text): blocks[index, default: Block(type: "text")].text += text
        case .thinkingDelta(let index, let text): blocks[index, default: Block(type: "thinking")].text += text
        case .signatureDelta(let index, let signature): blocks[index, default: Block(type: "thinking")].signature += signature
        case .rawBlock(let index, let block): blocks[index, default: Block(type: block["type"]?.stringValue ?? "unknown")].raw = block
        case .inputDelta(let index, let partial): blocks[index]?.partialInput += partial
        case .citationDelta(let index, let citation): blocks[index]?.citations.append(citation)
        case .blockStopped(let index): blocks[index]?.completed = true
        default: break
        }
    }

    /// 서버 도구 호출의 이름과 입력(검색어·주소). 화면 표시용입니다.
    func serverTool(at index: Int) -> (name: String, detail: String)? {
        guard let block = blocks[index], block.type == "server_tool_use", let raw = block.raw else { return nil }
        let input = (try? JSONValue.parse(block.partialInput)) ?? raw["input"]
        return (raw["name"]?.stringValue ?? "", input?["query"]?.stringValue ?? input?["url"]?.stringValue ?? "")
    }

    /// 결과가 아직 없는 서버 도구 호출도 남깁니다. pause_turn 뒤에 이어 달라고 그대로 돌려보낼 때 씁니다.
    var resumableContent: [JSONValue] { assembled }

    /// 완료된 블록만 돌려줍니다. 중단된 thinking 블록은 서명이 없어 되돌려 보낼 수 없으므로 뺍니다.
    /// 결과 없이 끝난 서버 도구 호출은 뺍니다. 남기면 다음 요청이 그 호출을 이어 달라는 뜻이 됩니다.
    var completedContent: [JSONValue] {
        let answered = Set(assembled.compactMap { $0["tool_use_id"]?.stringValue })
        return assembled.filter { block in
            guard block["type"]?.stringValue == "server_tool_use" else { return true }
            return answered.contains(block["id"]?.stringValue ?? "")
        }
    }

    private var assembled: [JSONValue] {
        blocks.keys.sorted().compactMap { index in
            guard let block = blocks[index], block.completed else { return nil }
            switch block.type {
            case "text":
                guard !block.text.isEmpty else { return nil }
                var object: [String: JSONValue] = ["type": "text", "text": .string(block.text)]
                // 인용은 다음 턴에 받은 그대로 돌려보내야 합니다.
                if !block.citations.isEmpty { object["citations"] = .array(block.citations) }
                return .object(object)
            case "thinking":
                return ["type": "thinking", "thinking": .string(block.text), "signature": .string(block.signature)]
            default:
                guard var object = block.raw?.objectValue else { return nil }
                if !block.partialInput.isEmpty, let input = try? JSONValue.parse(block.partialInput) { object["input"] = input }
                if block.type == "server_tool_use", object["input"] == nil { object["input"] = .object([:]) }
                return .object(object)
            }
        }
    }

    /// 중단됐을 때 화면에 남길 부분 텍스트 (서버로는 보내지 않음)
    var partialText: String {
        blocks.keys.sorted().compactMap { blocks[$0] }.filter { $0.type == "text" }.map(\.text).joined()
    }
}
