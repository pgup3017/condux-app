import XCTest
@testable import Condux

/// 네트워크 없이 가짜 전송 계층으로 Messages API 요청 모양과 SSE 해석을 검사합니다.
final class FakeAPITransport: ClaudeAPITransport {
    var status = 200
    var lines: [String] = []
    /// 비어 있지 않으면 요청마다 앞에서부터 하나씩 꺼내 씁니다(릴레이처럼 여러 턴을 흉내 낼 때).
    var responseQueue: [[String]] = []
    /// 비어 있지 않으면 요청마다 앞에서부터 하나씩 꺼내 상태 코드로 씁니다.
    var statusQueue: [Int] = []
    var neverFinish = false
    var holdRequestNumber: Int?
    private(set) var requests: [URLRequest] = []
    private var held: AsyncThrowingStream<String, Error>.Continuation?

    func send(_ request: URLRequest) async throws -> (status: Int, lines: AsyncThrowingStream<String, Error>) {
        requests.append(request)
        let lines = responseQueue.isEmpty ? self.lines : responseQueue.removeFirst()
        let hang = neverFinish || holdRequestNumber == requests.count
        let stream = AsyncThrowingStream<String, Error> { continuation in
            for line in lines { continuation.yield(line) }
            if hang { self.held = continuation } else { continuation.finish() }
        }
        return (statusQueue.isEmpty ? status : statusQueue.removeFirst(), stream)
    }

    var lastBody: JSONValue? {
        requests.last?.httpBody.flatMap { try? JSONValue.parse($0) }
    }

    static func sse(_ events: [(String, String)]) -> [String] {
        events.flatMap { ["event: \($0.0)", "data: \($0.1)", ""] }
    }

    /// 실제 API 가 보내는 순서를 흉내 낸 한 턴 (생각 블록 + 텍스트 블록)
    /// 공식 문서의 스트리밍 예시 형식을 따른 웹 검색 턴
    static func webSearchTurn(stop: String = "end_turn") -> [String] {
        sse([
            ("message_start", #"{"type":"message_start","message":{"id":"msg_w","type":"message","role":"assistant","model":"claude-opus-5-5","content":[],"usage":{"input_tokens":100,"output_tokens":1}}}"#),
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"찾아보겠습니다. "}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
            ("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"server_tool_use","id":"srvtoolu_1","name":"web_search"}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"query\":"}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\"오늘 날씨\"}"}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":1}"#),
            ("content_block_start", #"{"type":"content_block_start","index":2,"content_block":{"type":"web_search_tool_result","tool_use_id":"srvtoolu_1","content":[{"type":"web_search_result","title":"날씨","url":"https://example.com/w","encrypted_content":"ENC123","page_age":"today"}]}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":2}"#),
            ("content_block_start", #"{"type":"content_block_start","index":3,"content_block":{"type":"text","text":""}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":3,"delta":{"type":"citations_delta","citation":{"type":"web_search_result_location","url":"https://example.com/w","title":"날씨 [속보]","encrypted_index":"IDX1","cited_text":"맑음"}}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":3,"delta":{"type":"text_delta","text":"맑습니다."}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":3}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"\#(stop)"},"usage":{"output_tokens":50,"server_tool_use":{"web_search_requests":1}}}"#),
            ("message_stop", #"{"type":"message_stop"}"#),
        ])
    }

    static let happyTurn = sse([
        ("message_start", #"{"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude-opus-5-5","content":[],"usage":{"input_tokens":20,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1}}}"#),
        ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#),
        ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"요약된 생각"}}"#),
        ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig123"}}"#),
        ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
        ("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#),
        ("ping", #"{"type":"ping"}"#),
        ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"안녕"}}"#),
        ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"하세요"}}"#),
        ("content_block_stop", #"{"type":"content_block_stop","index":1}"#),
        ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":50}}"#),
        ("message_stop", #"{"type":"message_stop"}"#),
    ])
}

/// HTTP 전송 시작과 응답을 읽는 중의 오류를 각각 흉내 냅니다.
struct FailingAPITransport: ClaudeAPITransport {
    let error: Error
    var whileReading = false

    func send(_ request: URLRequest) async throws -> (status: Int, lines: AsyncThrowingStream<String, Error>) {
        if !whileReading { throw error }
        return (200, AsyncThrowingStream { $0.finish(throwing: error) })
    }
}

@MainActor
final class ClaudeAPIClientTests: XCTestCase {
    func testRequestShapeAndHeaders() throws {
        let request = ClaudeAPIRequest(model: "claude-opus-5-5", system: "한국어로", messages: [["role": "user", "content": "hi"]],
                                       maxTokens: 4096, effort: "high")
        let url = try request.urlRequest(apiKey: "sk-test")
        XCTAssertEqual(url.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(url.value(forHTTPHeaderField: "x-api-key"), "sk-test")
        XCTAssertEqual(url.value(forHTTPHeaderField: "anthropic-version"), "2026-10-21")
        XCTAssertNil(url.value(forHTTPHeaderField: "anthropic-beta"), "기본은 서버 fallback 끔")
        let body = try JSONValue.parse(try XCTUnwrap(url.httpBody))
        XCTAssertEqual(body["model"]?.stringValue, "claude-opus-5-5")
        XCTAssertEqual(body["stream"]?.boolValue, true)
        XCTAssertEqual(body["max_tokens"]?.intValue, 4096)
        XCTAssertEqual(body["system"]?.stringValue, "한국어로")
        XCTAssertEqual(body["thinking"]?["type"]?.stringValue, "adaptive")
        XCTAssertEqual(body["thinking"]?["display"]?.stringValue, "summarized")
        XCTAssertEqual(body["output_config"]?["effort"]?.stringValue, "high")
        XCTAssertNil(body["fallbacks"])
        XCTAssertNil(body["temperature"])
    }

    func testStreamParsesEventsAndAssemblesBlocks() async throws {
        let transport = FakeAPITransport()
        transport.lines = FakeAPITransport.happyTurn
        let client = ClaudeAPIClient(transport: transport)
        var events: [ClaudeAPIEvent] = []
        var assembler = ClaudeAPIBlockAssembler()
        try await client.stream(ClaudeAPIRequest(model: "claude-opus-5-5", system: "", messages: [], maxTokens: 100), apiKey: "sk-test") { event in
            events.append(event)
            assembler.apply(event)
        }
        var text = ""; var thinking = ""; var stop = ""; var usage = ClaudeAPIUsage(); var served = ""
        for event in events {
            switch event {
            case .textDelta(_, let t): text += t
            case .thinkingDelta(_, let t): thinking += t
            case .finished(let reason, _): stop = reason
            case .usage(let u): usage = u
            case .started(let model, _): served = model
            default: break
            }
        }
        XCTAssertEqual(text, "안녕하세요")
        XCTAssertEqual(thinking, "요약된 생각")
        XCTAssertEqual(stop, "end_turn")
        XCTAssertEqual(served, "claude-opus-5-5")
        XCTAssertEqual(usage, ClaudeAPIUsage(inputTokens: 20, outputTokens: 50, cacheReadTokens: 0, cacheWriteTokens: 0))

        let content = assembler.completedContent
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[0]["type"]?.stringValue, "thinking")
        XCTAssertEqual(content[0]["signature"]?.stringValue, "sig123", "thinking 블록은 서명째 돌려보내야 합니다")
        XCTAssertEqual(content[1]["text"]?.stringValue, "안녕하세요")
    }

    func testHTTPErrorBecomesTypedError() async {
        let transport = FakeAPITransport()
        transport.status = 401
        transport.lines = [#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#]
        let client = ClaudeAPIClient(transport: transport)
        do {
            try await client.stream(ClaudeAPIRequest(model: "claude-opus-5-5", system: "", messages: [], maxTokens: 100), apiKey: "sk-bad") { _ in }
            XCTFail("401 은 오류여야 합니다")
        } catch let error as ClaudeAPIError {
            XCTAssertEqual(error, .http(status: 401, type: "authentication_error", message: "invalid x-api-key"))
            XCTAssertTrue(error.localizedDescription.contains("401"))
        } catch {
            XCTFail("다른 오류: \(error)")
        }
    }

    func testMissingKeyNeverSendsRequest() async {
        let transport = FakeAPITransport()
        let client = ClaudeAPIClient(transport: transport)
        do {
            try await client.stream(ClaudeAPIRequest(model: "claude-opus-5-5", system: "", messages: [], maxTokens: 100), apiKey: "  ") { _ in }
            XCTFail("키 없이 보내면 안 됩니다")
        } catch let error as ClaudeAPIError {
            XCTAssertEqual(error, .missingKey)
        } catch { XCTFail("다른 오류: \(error)") }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testIncompleteThinkingBlockIsDroppedOnInterrupt() {
        var assembler = ClaudeAPIBlockAssembler()
        assembler.apply(.blockStarted(index: 0, type: "thinking"))
        assembler.apply(.thinkingDelta(index: 0, text: "생각 중"))
        assembler.apply(.blockStarted(index: 1, type: "text"))
        assembler.apply(.textDelta(index: 1, text: "부분 답"))
        XCTAssertTrue(assembler.completedContent.isEmpty, "서명 없는 thinking 과 미완 text 는 서버로 보내지 않습니다")
        XCTAssertEqual(assembler.partialText, "부분 답")
    }

    func testPricingEstimates() {
        let opus = ClaudePricing.forModel("claude-opus-5-5")
        XCTAssertTrue(opus.known)
        let cost = opus.estimate(ClaudeAPIUsage(inputTokens: 1_000_000, outputTokens: 100_000, cacheReadTokens: 0, cacheWriteTokens: 0))
        XCTAssertEqual(cost, 4 + 2, accuracy: 0.0001)
        let unknown = ClaudePricing.forModel("claude-future-9")
        XCTAssertFalse(unknown.known)
        XCTAssertEqual(unknown.output, 50, "모르는 모델은 가장 비싼 요율로 추정")
        let haiku = ClaudePricing.forModel("claude-haiku-5-5").estimate(ClaudeAPIUsage(inputTokens: 1000, outputTokens: 1000, cacheReadTokens: 0, cacheWriteTokens: 0))
        XCTAssertEqual(haiku, 0.0006, accuracy: 0.00001)
    }
    func testDiagnosticsRedactKeysAndHeaderVariants() {
        let key = "fixture-current-key-1234"
        let values = [
            "Authorization: Bearer header-secret",
            "aUtHoRiZaTiOn=Basic another-secret",
            #"{"Authorization":"Bearer json-secret","x-api-key":"json-api-secret"}"#,
            "'X-API-KEY': 'quoted-secret'",
            "Bearer standalone-secret",
            "x-api-key: first-secret\r\nAuthorization: Bearer second-secret",
            "key=\(key); other=sk-ant-fake-other-key",
        ]
        for text in values {
            let safe = APIDiagnostics.redacted(text, apiKey: key)
            for secret in [key, "header-secret", "another-secret", "json-secret", "json-api-secret", "quoted-secret",
                           "standalone-secret", "first-secret", "second-secret", "sk-ant-fake-other-key"] {
                XCTAssertFalse(safe.contains(secret))
            }
            XCTAssertTrue(safe.contains("[가림]"))
        }
        XCTAssertEqual(APIDiagnostics.redacted("billing_error: 잔액 부족", apiKey: key), "billing_error: 잔액 부족")
    }

    func testHTTPDiagnosticsNeverExposeKeysEvenBeforeDescriptionOrTruncation() async throws {
        let key = "fixture-" + String(repeating: "z", count: 400)
        for status in [400, 401, 402, 500] {
            for jsonBody in [true, false] {
                let transport = FakeAPITransport()
                transport.status = status
                let message = "잔액 확인 \(key)\nAuthorization: Bearer header-secret\nx-api-key: api-secret"
                let body: JSONValue = ["error": ["type": .string(key), "message": .string(message)]]
                transport.lines = [jsonBody ? try body.compactJSON() : message]
                do {
                    try await ClaudeAPIClient(transport: transport).stream(
                        ClaudeAPIRequest(model: "claude-opus-5-5", system: "", messages: [], maxTokens: 100), apiKey: key) { _ in }
                    XCTFail("HTTP 오류가 필요합니다")
                } catch {
                    let diagnostic = String(describing: error) + error.localizedDescription
                    for secret in [String(key.prefix(80)), "header-secret", "api-secret"] {
                        XCTAssertFalse(diagnostic.contains(secret))
                    }
                    XCTAssertTrue(error is ClaudeAPIError)
                }
            }
        }
    }

    func testStreamErrorsRedactBothTypeAndMessage() async throws {
        let key = "fixture-stream-key"
        let transport = FakeAPITransport()
        let body: JSONValue = ["type": "error", "error": ["type": .string(key),
            "message": .string("\(key)\nAuthorization: Bearer header-secret\nx-api-key: api-secret")]]
        transport.lines = FakeAPITransport.sse([("error", try body.compactJSON())])
        do {
            try await ClaudeAPIClient(transport: transport).stream(
                ClaudeAPIRequest(model: "claude-opus-5-5", system: "", messages: [], maxTokens: 100), apiKey: key) { _ in }
            XCTFail("스트림 오류가 필요합니다")
        } catch {
            let diagnostic = String(describing: error) + error.localizedDescription
            for secret in [key, "header-secret", "api-secret"] { XCTAssertFalse(diagnostic.contains(secret)) }
            XCTAssertTrue(diagnostic.contains("[가림]"))
        }
    }

    func testMalformedAndUnknownEventsDoNotLogResponseContents() async throws {
        let key = "fixture-log-key"
        let transport = FakeAPITransport()
        let unknown: JSONValue = ["type": .string(key)]
        let delta: JSONValue = ["type": "content_block_delta", "delta": ["type": .string("Authorization: Bearer header-secret")]]
        transport.lines = ["data: \(key) Authorization: Bearer header-secret"]
            + FakeAPITransport.sse([("unknown", try unknown.compactJSON()), ("delta", try delta.compactJSON())])
        var logs: [String] = []
        try await ClaudeAPIClient(transport: transport).stream(
            ClaudeAPIRequest(model: key, system: "", messages: [], maxTokens: 100), apiKey: key) {
                if case .log(let text) = $0 { logs.append(text) }
            }
        XCTAssertEqual(logs.count, 4)
        XCTAssertFalse(logs.joined().contains(key))
        XCTAssertFalse(logs.joined().contains("header-secret"))
    }

    func testTransportErrorsNeverExposeUnderlyingDiagnostic() async {
        let key = "fixture-transport-key"
        for whileReading in [false, true] {
            for error: Error in [
                NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(key) Authorization: Bearer secret"]),
                URLError(.notConnectedToInternet, userInfo: [NSLocalizedDescriptionKey: "\(key) x-api-key: secret"]),
            ] {
                do {
                    try await ClaudeAPIClient(transport: FailingAPITransport(error: error, whileReading: whileReading)).stream(
                        ClaudeAPIRequest(model: "claude-opus-5-5", system: "", messages: [], maxTokens: 100), apiKey: key) { _ in }
                    XCTFail("전송 오류가 필요합니다")
                } catch {
                    XCTAssertFalse((String(describing: error) + error.localizedDescription).contains(key))
                    XCTAssertFalse(error.localizedDescription.contains("secret"))
                    XCTAssertTrue(error.localizedDescription.contains("API 연결에 실패했습니다"))
                }
            }
        }
    }

    func testTransportCancellationRemainsCancellation() async {
        for error: Error in [CancellationError(), URLError(.cancelled)] {
            do {
                try await ClaudeAPIClient(transport: FailingAPITransport(error: error)).stream(
                    ClaudeAPIRequest(model: "claude-opus-5-5", system: "", messages: [], maxTokens: 100), apiKey: "fixture-key") { _ in }
                XCTFail("취소 오류가 필요합니다")
            } catch {
                XCTAssertEqual(error as? ClaudeAPIError, .cancelled)
            }
        }
    }

}
