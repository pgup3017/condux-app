import XCTest
@testable import Condux

/// 네트워크 없이 가짜 전송 계층으로 OpenAI Responses API 요청 모양과 SSE 해석을 검사합니다.
@MainActor
final class OpenAIAPIClientTests: XCTestCase {
    /// 실제 Responses API 스트림의 순서를 흉내 낸 한 턴 (추론 요약 + 텍스트)
    static let happyTurn = FakeAPITransport.sse([
        ("response.created", #"{"type":"response.created","sequence_number":0,"response":{"id":"resp_1","object":"response","model":"gpt-6.1-sol","status":"in_progress","output":[]}}"#),
        ("response.in_progress", #"{"type":"response.in_progress","sequence_number":1,"response":{"id":"resp_1","status":"in_progress"}}"#),
        ("response.output_item.added", #"{"type":"response.output_item.added","sequence_number":2,"output_index":0,"item":{"id":"rs_1","type":"reasoning","summary":[]}}"#),
        ("response.reasoning_summary_text.delta", #"{"type":"response.reasoning_summary_text.delta","sequence_number":3,"item_id":"rs_1","output_index":0,"summary_index":0,"delta":"요약된 추론"}"#),
        ("response.reasoning_summary_text.done", #"{"type":"response.reasoning_summary_text.done","sequence_number":4,"item_id":"rs_1","output_index":0,"summary_index":0,"text":"요약된 추론"}"#),
        ("response.output_item.added", #"{"type":"response.output_item.added","sequence_number":5,"output_index":1,"item":{"id":"msg_1","type":"message","role":"assistant","content":[]}}"#),
        ("response.content_part.added", #"{"type":"response.content_part.added","sequence_number":6,"item_id":"msg_1","output_index":1,"content_index":0,"part":{"type":"output_text","text":""}}"#),
        ("response.output_text.delta", #"{"type":"response.output_text.delta","sequence_number":7,"item_id":"msg_1","output_index":1,"content_index":0,"delta":"안녕"}"#),
        ("response.output_text.delta", #"{"type":"response.output_text.delta","sequence_number":8,"item_id":"msg_1","output_index":1,"content_index":0,"delta":"하세요"}"#),
        ("response.output_text.done", #"{"type":"response.output_text.done","sequence_number":9,"item_id":"msg_1","output_index":1,"content_index":0,"text":"안녕하세요"}"#),
        ("response.completed", #"{"type":"response.completed","sequence_number":10,"response":{"id":"resp_1","model":"gpt-6.1-sol","status":"completed","usage":{"input_tokens":120,"input_tokens_details":{"cached_tokens":100},"output_tokens":40,"output_tokens_details":{"reasoning_tokens":10},"total_tokens":160}}}"#),
    ])

    func testRequestShapeAndHeaders() throws {
        let request = OpenAIAPIRequest(model: "gpt-6.1-sol", instructions: "한국어로",
                                       input: [OpenAIAPIRequest.userItem("hi")], maxOutputTokens: 4096, effort: "medium")
        let url = try request.urlRequest(apiKey: "sk-test")
        XCTAssertEqual(url.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(url.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        let body = try JSONValue.parse(try XCTUnwrap(url.httpBody))
        XCTAssertEqual(body["model"]?.stringValue, "gpt-6.1-sol")
        XCTAssertEqual(body["stream"]?.boolValue, true)
        XCTAssertEqual(body["store"]?.boolValue, false, "기록은 앱이 들고 다시 보내므로 서버 저장을 끕니다")
        XCTAssertEqual(body["max_output_tokens"]?.intValue, 4096)
        XCTAssertEqual(body["instructions"]?.stringValue, "한국어로")
        XCTAssertEqual(body["reasoning"]?["effort"]?.stringValue, "medium")
        XCTAssertEqual(body["input"]?[0]?["role"]?.stringValue, "user")
        XCTAssertEqual(body["input"]?[0]?["content"]?[0]?["type"]?.stringValue, "input_text")
        XCTAssertNil(body["temperature"])

        let noEffort = OpenAIAPIRequest(model: "gpt-6-luna", instructions: "", input: [], maxOutputTokens: 100)
        let plain = try JSONValue.parse(try XCTUnwrap(try noEffort.urlRequest(apiKey: "k").httpBody))
        XCTAssertNil(plain["reasoning"], "추론 수준을 고르지 않으면 보내지 않습니다")
        XCTAssertNil(plain["instructions"])
    }

    func testStreamParsesTextReasoningAndUsage() async throws {
        let transport = FakeAPITransport()
        transport.lines = Self.happyTurn
        let client = OpenAIAPIClient(transport: transport)
        var events: [ClaudeAPIEvent] = []
        var assembler = ClaudeAPIBlockAssembler()
        try await client.stream(OpenAIAPIRequest(model: "gpt-6.1-sol", instructions: "", input: [], maxOutputTokens: 100), apiKey: "sk-test") { event in
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
        XCTAssertEqual(thinking, "요약된 추론")
        XCTAssertEqual(stop, "end_turn")
        XCTAssertEqual(served, "gpt-6.1-sol")
        // 캐시된 100 토큰은 input_tokens 안에 포함되어 오므로 비캐시 입력 20 + 캐시 100 으로 나눕니다.
        XCTAssertEqual(usage, ClaudeAPIUsage(inputTokens: 20, outputTokens: 40, cacheReadTokens: 100, cacheWriteTokens: 0))
        let texts = assembler.completedContent.compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }
        XCTAssertEqual(texts, ["안녕하세요"])
    }

    func testIncompleteBecomesMaxTokens() async throws {
        let transport = FakeAPITransport()
        transport.lines = FakeAPITransport.sse([
            ("response.created", #"{"type":"response.created","response":{"id":"resp_2","model":"gpt-6-luna"}}"#),
            ("response.output_text.delta", #"{"type":"response.output_text.delta","item_id":"m","output_index":0,"content_index":0,"delta":"부분"}"#),
            ("response.incomplete", #"{"type":"response.incomplete","response":{"id":"resp_2","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"usage":{"input_tokens":5,"output_tokens":3}}}"#),
        ])
        var stop = ""
        try await OpenAIAPIClient(transport: transport).stream(OpenAIAPIRequest(model: "gpt-6-luna", instructions: "", input: [], maxOutputTokens: 3), apiKey: "k") { event in
            if case .finished(let reason, _) = event { stop = reason }
        }
        XCTAssertEqual(stop, "max_tokens")
    }

    func testHTTPErrorBecomesTypedError() async {
        let transport = FakeAPITransport()
        transport.status = 401
        transport.lines = [#"{"error":{"message":"Incorrect API key provided","type":"invalid_request_error","code":"invalid_api_key"}}"#]
        do {
            try await OpenAIAPIClient(transport: transport).stream(OpenAIAPIRequest(model: "gpt-6-luna", instructions: "", input: [], maxOutputTokens: 10), apiKey: "bad") { _ in }
            XCTFail("401 은 오류여야 합니다")
        } catch let error as ClaudeAPIError {
            XCTAssertEqual(error, .http(status: 401, type: "invalid_request_error", message: "Incorrect API key provided"))
        } catch { XCTFail("다른 오류: \(error)") }
    }

    func testPricing() {
        XCTAssertTrue(OpenAIPricing.forModel("gpt-6.1-sol").known)
        let cost = OpenAIPricing.forModel("gpt-6.1-sol").estimate(ClaudeAPIUsage(inputTokens: 1_000_000, outputTokens: 100_000, cacheReadTokens: 0, cacheWriteTokens: 0))
        XCTAssertEqual(cost, 2 + 1, accuracy: 0.0001)
        let unknown = OpenAIPricing.forModel("gpt-9-future")
        XCTAssertFalse(unknown.known)
        XCTAssertEqual(unknown.output, 50, "모르는 모델은 gpt-6-astra 요율로 추정")
    }
    func testHTTPDiagnosticsNeverExposeKeysEvenBeforeDescriptionOrTruncation() async throws {
        let key = "fixture-openai-" + String(repeating: "z", count: 400)
        for status in [400, 401, 402, 500] {
            for jsonBody in [true, false] {
                let transport = FakeAPITransport()
                transport.status = status
                let message = "잔액 확인 \(key)\nAuthorization: Bearer header-secret\nx-api-key: api-secret"
                let body: JSONValue = ["error": ["code": .string(key), "message": .string(message)]]
                transport.lines = [jsonBody ? try body.compactJSON() : message]
                do {
                    try await OpenAIAPIClient(transport: transport).stream(
                        OpenAIAPIRequest(model: "gpt-6.1-sol", instructions: "", input: [], maxOutputTokens: 100), apiKey: key) { _ in }
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

    func testFailedAndErrorEventsRedactBothTypeAndMessage() async throws {
        let key = "fixture-openai-stream-key"
        let message = "\(key)\nAuthorization: Bearer header-secret\nx-api-key: api-secret"
        let error: JSONValue = ["code": .string(key), "type": .string(key), "message": .string(message)]
        let bodies: [JSONValue] = [
            ["type": "response.failed", "response": ["error": error]],
            ["type": "error", "code": .string(key), "message": .string(message)],
            ["type": "error", "error": error],
        ]
        for body in bodies {
            let transport = FakeAPITransport()
            transport.lines = FakeAPITransport.sse([("error", try body.compactJSON())])
            do {
                try await OpenAIAPIClient(transport: transport).stream(
                    OpenAIAPIRequest(model: "gpt-6.1-sol", instructions: "", input: [], maxOutputTokens: 100), apiKey: key) { _ in }
                XCTFail("스트림 오류가 필요합니다")
            } catch {
                let diagnostic = String(describing: error) + error.localizedDescription
                for secret in [key, "header-secret", "api-secret"] { XCTAssertFalse(diagnostic.contains(secret)) }
                XCTAssertTrue(diagnostic.contains("[가림]"))
            }
        }
    }

    func testMalformedEventsAndRequestLogDoNotExposeKeys() async throws {
        let key = "fixture-openai-log-key"
        let transport = FakeAPITransport()
        transport.lines = ["data: \(key) Authorization: Bearer header-secret", "data: [DONE]"]
        var logs: [String] = []
        try await OpenAIAPIClient(transport: transport).stream(
            OpenAIAPIRequest(model: key, instructions: "", input: [], maxOutputTokens: 100), apiKey: key) {
                if case .log(let text) = $0 { logs.append(text) }
            }
        XCTAssertEqual(logs.count, 2)
        XCTAssertFalse(logs.joined().contains(key))
        XCTAssertFalse(logs.joined().contains("header-secret"))
    }

    func testTransportErrorsNeverExposeUnderlyingDiagnostic() async {
        let key = "fixture-openai-transport-key"
        for whileReading in [false, true] {
            for error: Error in [
                NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(key) Authorization: Bearer secret"]),
                URLError(.notConnectedToInternet, userInfo: [NSLocalizedDescriptionKey: "\(key) x-api-key: secret"]),
            ] {
                do {
                    try await OpenAIAPIClient(transport: FailingAPITransport(error: error, whileReading: whileReading)).stream(
                        OpenAIAPIRequest(model: "gpt-6.1-sol", instructions: "", input: [], maxOutputTokens: 100), apiKey: key) { _ in }
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
                try await OpenAIAPIClient(transport: FailingAPITransport(error: error)).stream(
                    OpenAIAPIRequest(model: "gpt-6.1-sol", instructions: "", input: [], maxOutputTokens: 100), apiKey: "fixture-key") { _ in }
                XCTFail("취소 오류가 필요합니다")
            } catch {
                XCTAssertEqual(error as? ClaudeAPIError, .cancelled)
            }
        }
    }

}
