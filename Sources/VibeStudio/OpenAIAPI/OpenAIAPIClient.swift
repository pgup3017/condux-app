import Foundation

/// OpenAI Responses API(`POST /v1/responses`, SSE 스트리밍)를 사용자 자신의 API 키로 직접 호출합니다.
/// Claude API 연결과 같은 이벤트·전송 계층(`ClaudeAPIEvent`, `ClaudeAPITransport`)을 재사용해
/// AppModel 이 두 연결을 같은 방식으로 다룹니다. 참고: https://developers.openai.com/api/docs/api-reference/responses

// MARK: 요금표 (추정용)

enum OpenAIPricing {
    /// 1M 토큰당 달러. 2026-10 기준 OpenAI 공식 요금 페이지(표준 등급, 짧은 문맥). 추정치로만 씁니다.
    static let table: [String: ClaudePricing] = [
        "gpt-6-astra":   ClaudePricing(input: 10,   output: 50,   cacheRead: 1.0,   cacheWrite: 10),
        "gpt-6.1-sol":   ClaudePricing(input: 2,    output: 10,   cacheRead: 0.10,  cacheWrite: 2),
        "gpt-6.1-terra": ClaudePricing(input: 1,    output: 5,    cacheRead: 0.05,  cacheWrite: 1),
        "gpt-6-sol":     ClaudePricing(input: 2,    output: 10,   cacheRead: 0.20,  cacheWrite: 2),
        "gpt-6-luna":    ClaudePricing(input: 0.10, output: 0.50, cacheRead: 0.01,  cacheWrite: 0.10),
        "gpt-5.6-sol":   ClaudePricing(input: 4,    output: 20,   cacheRead: 0.40,  cacheWrite: 4),
        "gpt-5.6-terra": ClaudePricing(input: 2,    output: 12,   cacheRead: 0.20,  cacheWrite: 2),
        "gpt-5.6-luna":  ClaudePricing(input: 0.20, output: 1.20, cacheRead: 0.02,  cacheWrite: 0.20),
        "gpt-5.5":       ClaudePricing(input: 5,    output: 30,   cacheRead: 0.50,  cacheWrite: 5),
        "gpt-5.4":       ClaudePricing(input: 2.5,  output: 15,   cacheRead: 0.25,  cacheWrite: 2.5),
        "gpt-5.4-mini":  ClaudePricing(input: 0.75, output: 4.5,  cacheRead: 0.075, cacheWrite: 0.75),
        "gpt-5.4-nano":  ClaudePricing(input: 0.20, output: 1.25, cacheRead: 0.02,  cacheWrite: 0.20),
        "gpt-5.1":       ClaudePricing(input: 1.25, output: 10,   cacheRead: 0.125, cacheWrite: 1.25),
        "gpt-5":         ClaudePricing(input: 1.25, output: 10,   cacheRead: 0.125, cacheWrite: 1.25),
        "gpt-5-mini":    ClaudePricing(input: 0.25, output: 2,    cacheRead: 0.025, cacheWrite: 0.25),
        "gpt-5-nano":    ClaudePricing(input: 0.05, output: 0.40, cacheRead: 0.005, cacheWrite: 0.05),
    ]

    /// 모르는 모델은 가장 비싼 일반 모델(gpt-6-astra) 요율로 보수적으로 추정합니다.
    static func forModel(_ model: String) -> ClaudePricing {
        if let exact = table[model] { return exact }
        var fallback = table["gpt-6-astra"]!
        fallback.known = false
        return fallback
    }
}

// MARK: 요청

struct OpenAIAPIRequest {
    var model: String
    var instructions: String
    /// Responses API 의 input 항목들 (role + content). 이전 턴은 텍스트만 다시 보냅니다.
    var input: [JSONValue]
    var maxOutputTokens: Int
    /// reasoning.effort (low/medium/high 등). 비우면 보내지 않습니다.
    var effort: String = ""
    /// 서버에서 실행되는 도구. 비어 있으면 보내지 않습니다.
    var tools: [JSONValue] = []

    static let webTools: [JSONValue] = [["type": "web_search"]]
    static let endpoint = URL(string: "https://api.openai.com/v1/responses")!

    func body() -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "input": .array(input),
            "max_output_tokens": .number(Double(maxOutputTokens)),
            "stream": true,
            "store": false, // 기록은 앱이 들고 다시 보냅니다. OpenAI 서버에 30일 보관하지 않습니다.
        ]
        if !instructions.isEmpty { body["instructions"] = .string(instructions) }
        if !effort.isEmpty { body["reasoning"] = ["effort": .string(effort), "summary": "auto"] }
        if !tools.isEmpty { body["tools"] = .array(tools) }
        return .object(body)
    }

    func urlRequest(apiKey: String) throws -> URLRequest {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(try body().compactJSON().utf8)
        return request
    }

    static func userItem(_ text: String) -> JSONValue {
        ["role": "user", "content": [["type": "input_text", "text": .string(text)]]]
    }

    static func assistantItem(_ text: String) -> JSONValue {
        ["role": "assistant", "content": [["type": "output_text", "text": .string(text)]]]
    }
}

// MARK: 클라이언트

final class OpenAIAPIClient {
    private let transport: ClaudeAPITransport

    init(transport: ClaudeAPITransport = URLSessionTransport()) {
        self.transport = transport
    }

    /// 한 턴을 스트리밍합니다. 이벤트는 Claude API 와 같은 `ClaudeAPIEvent` 로 올라옵니다.
    /// - 텍스트: `response.output_text.delta` → `.textDelta`
    /// - 추론 요약: `response.reasoning_summary_text.delta` → `.thinkingDelta`
    /// - 끝: `response.completed` / `response.incomplete` → `.usage` + `.finished`
    func stream(_ request: OpenAIAPIRequest, apiKey: String, onEvent: @escaping @MainActor (ClaudeAPIEvent) -> Void) async throws {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ClaudeAPIError.missingKey }
        do {
            let urlRequest = try request.urlRequest(apiKey: key)
            await onEvent(.log(APIDiagnostics.redacted("→ POST /v1/responses model=\(request.model) max_output_tokens=\(request.maxOutputTokens) input=\(request.input.count)", apiKey: key)))

            let (status, lines) = try await transport.send(urlRequest)
            if status < 200 || status >= 300 {
                var text = ""
                for try await line in lines { text += line }
                let json = try? JSONValue.parse(text)
                throw ClaudeAPIError.http(status: status,
                                          type: json?["error"]?["type"]?.stringValue ?? json?["error"]?["code"]?.stringValue ?? "unknown",
                                          message: json?["error"]?["message"]?.stringValue ?? String(APIDiagnostics.redacted(text, apiKey: key).prefix(300)))
            }

            var eventName = ""
            var textIndex = 0
            var thinkingIndex = 1
            var startedBlocks: Set<Int> = []
            var finished = false
            var webSearches = 0
            for try await rawLine in lines {
                try Task.checkCancellation()
                let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
                if line.isEmpty { eventName = ""; continue }
                if line.hasPrefix("event:") { eventName = line.dropFirst(6).trimmingCharacters(in: .whitespaces); continue }
                guard line.hasPrefix("data:") else { continue }
                let payloadText = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payloadText == "[DONE]" { break }
                guard let payload = try? JSONValue.parse(payloadText) else {
                    await onEvent(.log("! API 응답을 해석할 수 없습니다."))
                    continue
                }
                let type = payload["type"]?.stringValue ?? eventName
                switch type {
                case "response.created":
                    let response = payload["response"] ?? .null
                    await onEvent(.started(model: response["model"]?.stringValue ?? request.model,
                                           messageID: response["id"]?.stringValue ?? ""))
                case "response.web_search_call.in_progress", "response.web_search_call.searching":
                    await onEvent(.webActivity(key: payload["item_id"]?.stringValue ?? "web", name: "web_search", detail: ""))
                case "response.output_item.done" where payload["item"]?["type"]?.stringValue == "web_search_call":
                    let item = payload["item"] ?? .null
                    let action = item["action"] ?? .null
                    let isSearch = action["type"]?.stringValue == "search"
                    if isSearch { webSearches += 1 }
                    let detail = action["query"]?.stringValue ?? action["queries"]?[0]?.stringValue ?? action["url"]?.stringValue ?? ""
                    await onEvent(.webActivity(key: item["id"]?.stringValue ?? "web", name: isSearch ? "web_search" : "web_fetch", detail: detail))
                case "response.output_text.delta":
                    if !startedBlocks.contains(textIndex) {
                        startedBlocks.insert(textIndex)
                        await onEvent(.blockStarted(index: textIndex, type: "text"))
                    }
                    await onEvent(.textDelta(index: textIndex, text: payload["delta"]?.stringValue ?? ""))
                case "response.output_text.done":
                    await onEvent(.blockStopped(index: textIndex))
                    textIndex += 2
                    thinkingIndex += 2
                case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
                    if !startedBlocks.contains(thinkingIndex) {
                        startedBlocks.insert(thinkingIndex)
                        await onEvent(.blockStarted(index: thinkingIndex, type: "thinking"))
                    }
                    await onEvent(.thinkingDelta(index: thinkingIndex, text: payload["delta"]?.stringValue ?? ""))
                case "response.reasoning_summary_text.done", "response.reasoning_text.done":
                    await onEvent(.blockStopped(index: thinkingIndex))
                case "response.completed", "response.incomplete", "response.failed":
                    let response = payload["response"] ?? .null
                    var usage = ClaudeAPIUsage()
                    if let u = response["usage"], !u.isNull {
                        usage.inputTokens = u["input_tokens"]?.intValue ?? 0
                        usage.outputTokens = u["output_tokens"]?.intValue ?? 0
                        usage.cacheReadTokens = u["input_tokens_details"]?["cached_tokens"]?.intValue ?? 0
                        // OpenAI 는 캐시된 입력을 input_tokens 안에 포함해 세므로, 요율 계산을 위해 비캐시 입력으로 나눕니다.
                        usage.inputTokens = max(0, usage.inputTokens - usage.cacheReadTokens)
                        usage.webSearchRequests = webSearches
                        await onEvent(.usage(usage))
                    }
                    for item in response["output"]?.arrayValue ?? [] where item["type"]?.stringValue == "message" {
                        for part in item["content"]?.arrayValue ?? [] {
                            for note in part["annotations"]?.arrayValue ?? [] where note["type"]?.stringValue == "url_citation" {
                                if let url = note["url"]?.stringValue {
                                    await onEvent(.source(title: note["title"]?.stringValue ?? url, url: url))
                                }
                            }
                        }
                    }
                    // 끝난 블록 정리
                    for index in startedBlocks { await onEvent(.blockStopped(index: index)) }
                    let stop: String
                    switch type {
                    case "response.completed": stop = "end_turn"
                    case "response.incomplete":
                        stop = response["incomplete_details"]?["reason"]?.stringValue == "max_output_tokens" ? "max_tokens" : "incomplete"
                    default:
                        let error = response["error"] ?? .null
                        throw ClaudeAPIError.http(status: 200, type: error["code"]?.stringValue ?? "response_failed",
                                                  message: error["message"]?.stringValue ?? "응답 실패")
                    }
                    finished = true
                    await onEvent(.finished(stopReason: stop, stopDetails: response["incomplete_details"]))
                case "error":
                    throw ClaudeAPIError.http(status: 200, type: payload["code"]?.stringValue ?? payload["error"]?["type"]?.stringValue ?? "stream_error",
                                              message: payload["message"]?.stringValue ?? payload["error"]?["message"]?.stringValue ?? "스트림 오류")
                default:
                    break // response.in_progress, output_item.added, content_part.* 등은 화면에 필요 없습니다.
                }
                if finished { break }
            }
            try Task.checkCancellation()
        } catch {
            throw APIDiagnostics.safeError(error, apiKey: key)
        }
    }
}
