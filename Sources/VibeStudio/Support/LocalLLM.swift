import Foundation
import CryptoKit
#if canImport(MLXLLM) && !CONDUX_APPSTORE && arch(arm64)
import MLX
import MLXLLM
import MLXLMCommon
import Hub
#endif

struct LocalLLMMessage: Sendable, Equatable {
    enum Role: Sendable { case user, assistant }
    var role: Role
    var text: String
}

enum LocalLLMError: LocalizedError {
    case unavailable, modelMissing, downloadFailed, invalidFile, contextTooLong, notEnoughSpace

    var errorDescription: String? {
        switch self {
        case .unavailable: return "로컬 AI는 Apple Silicon Mac의 직접 설치판에서 사용할 수 있습니다."
        case .modelMissing: return "설정에서 로컬 AI 모델을 먼저 다운로드해 주세요."
        case .downloadFailed: return "모델을 다운로드하지 못했습니다. 인터넷 연결을 확인한 뒤 다시 누르면 받은 곳부터 이어받습니다."
        case .notEnoughSpace: return "저장 공간이 부족합니다. 약 1GB를 비운 뒤 다시 시도해 주세요."
        case .invalidFile: return "모델 파일 검증에 실패해 받은 파일을 지웠습니다. 다시 눌러 처음부터 받아 주세요."
        case .contextTooLong: return "시험용 로컬 AI는 대화 전체 8,000자까지 지원합니다. 새 로컬 대화를 시작해 주세요."
        }
    }
}

/// 다운로드는 별도 버튼으로만 시작합니다. 추론 중에는 이 저장소의 파일만 읽습니다.
struct LocalModelStore: Sendable {
    struct File: Sendable {
        let name: String
        let size: Int64
        let sha256: String
    }
    static let modelID = "mlx-community/Qwen3-1.7B-4bit"
    static let revision = "3b1b1768f8f8cf8351c712464f906e86c2b8269e"
    static let files: [File] = [
        File(name: "added_tokens.json", size: 707, sha256: "c0284b582e14987fbd3d5a2cb2bd139084371ed9acbae488829a1c900833c680"),
        File(name: "config.json", size: 937, sha256: "507a6701220524eb8b283425bf0856a9ae4f21f4052e563896ddd668994b1dc7"),
        File(name: "merges.txt", size: 1671853, sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
        File(name: "model.safetensors", size: 968080210, sha256: "0e86d9677e519323849eac1bc272caae88567a481ff188c431f70be543d9995f"),
        File(name: "model.safetensors.index.json", size: 49731, sha256: "1e3058d4ba4b04e4de35b74467725cbef90ff022198404218e48f21adc9cfa15"),
        File(name: "special_tokens_map.json", size: 613, sha256: "76862e765266b85aa9459767e33cbaf13970f327a0e88d1c65846c2ddd3a1ecd"),
        File(name: "tokenizer.json", size: 11422654, sha256: "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"),
        File(name: "tokenizer_config.json", size: 9706, sha256: "253153d0738ceb4c668d2eff957714dd2bea0b56de772a9fdccd96cbf517e6a0"),
        File(name: "vocab.json", size: 2776833, sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
    ]
    let root: URL
    var directory: URL { root.appendingPathComponent("qwen3-1.7b-4bit", isDirectory: true) }
    private var staging: URL { root.appendingPathComponent("qwen3-1.7b-4bit.partial", isDirectory: true) }
    private var marker: URL { directory.appendingPathComponent(".complete") }

    func isReady(files: [File] = Self.files) -> Bool {
        guard (try? String(contentsOf: marker, encoding: .utf8)) == Self.revision else { return false }
        return files.allSatisfy { file in
            let attributes = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(file.name).path)
            return attributes?[.size] as? Int64 == file.size
        }
    }

    /// 파일 하나를 받아 달라는 요청. `resumeFile` 에 끊긴 지점 정보가 있으면 거기서 이어받습니다.
    struct FetchRequest: Sendable {
        let url: URL
        let resumeFile: URL
        let onBytes: @Sendable (Int64) -> Void
    }
    typealias Fetch = @Sendable (FetchRequest) async throws -> (URL, URLResponse)

    /// 중단했거나 끊겨서 받다 만 파일이 있는지
    var hasPartial: Bool {
        !((try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []).isEmpty
    }

    /// 받은 양은 `progress(받은 바이트, 전체 바이트)` 로 알립니다. 중단·끊김이면 받은 파일을 남겨 다음에 이어받습니다.
    /// 검증에 실패한 경우에만 받은 것을 모두 지웁니다.
    func download(files: [File] = Self.files,
                  fetch: Fetch = ModelFileDownloader.fetch,
                  progress: @escaping @MainActor @Sendable (Int64, Int64) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        let spare = (try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
        if let spare, spare < total { throw LocalLLMError.notEnoughSpace }
        var completed: Int64 = 0
        let throttle = ProgressThrottle()
        for file in files {
            try Task.checkCancellation()
            let target = staging.appendingPathComponent(file.name)
            let resumeFile = staging.appendingPathComponent(file.name + ".resume")
            if !Self.isVerified(target, file) {
                try? fm.removeItem(at: target)
                let base = completed
                let url = URL(string: "https://huggingface.co/\(Self.modelID)/resolve/\(Self.revision)/\(file.name)")!
                let request = FetchRequest(url: url, resumeFile: resumeFile) { written in
                    guard throttle.allow() else { return }
                    let done = base + min(written, file.size)
                    Task { @MainActor in progress(done, total) }
                }
                let temporary = try await fetchChecked(request, fetch: fetch)
                defer { try? fm.removeItem(at: temporary) }
                try Task.checkCancellation()
                guard Self.isVerified(temporary, file) else {
                    try? fm.removeItem(at: staging)
                    throw LocalLLMError.invalidFile
                }
                try fm.moveItem(at: temporary, to: target)
                try? fm.removeItem(at: resumeFile)
            }
            completed += file.size
            await progress(completed, total)
        }
        try Task.checkCancellation()
        try Self.revision.write(to: staging.appendingPathComponent(".complete"), atomically: true, encoding: .utf8)
        if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
        try fm.moveItem(at: staging, to: directory)
    }

    /// 이어받기가 거절되면(서명 주소 만료, 임시 파일 삭제 등) 처음부터 한 번 다시 받습니다.
    /// 인터넷이 끊긴 경우에는 이어받을 정보를 지우지 않습니다.
    private func fetchChecked(_ request: FetchRequest, fetch: Fetch) async throws -> URL {
        let fm = FileManager.default
        let resuming = fm.fileExists(atPath: request.resumeFile.path)
        do {
            let (temporary, response) = try await fetch(request)
            let status = (response as? HTTPURLResponse)?.statusCode
            if status == 200 || (resuming && status == 206) { return temporary }
            try? fm.removeItem(at: temporary)
            guard resuming else { throw LocalLLMError.downloadFailed }
        } catch {
            if !resuming || error is CancellationError || Self.isConnectionProblem(error) { throw error }
        }
        try? fm.removeItem(at: request.resumeFile)
        return try await fetchChecked(request, fetch: fetch)
    }

    private static func isConnectionProblem(_ error: Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        return [.cancelled, .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
                .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff].contains(code)
    }

    private static func isVerified(_ url: URL, _ file: File) -> Bool {
        guard (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 == file.size,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == file.sha256
    }

    func delete() throws {
        for url in [directory, staging] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

/// 화면 갱신이 너무 잦지 않게 0.25초에 한 번만 통과시킵니다.
private final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    func allow() -> Bool {
        lock.withLock {
            guard Date().timeIntervalSince(last) >= 0.25 else { return false }
            last = Date()
            return true
        }
    }
}

/// URLSession 다운로드 한 건. 받은 양을 알리고, 끊기면 이어받을 정보를 파일로 남깁니다.
final class ModelFileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let fetch: LocalModelStore.Fetch = { request in
        try await ModelFileDownloader(request).run()
    }

    private let request: LocalModelStore.FetchRequest
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var task: URLSessionDownloadTask?
    private var result: (URL, URLResponse)?
    private var wasCancelled = false

    private init(_ request: LocalModelStore.FetchRequest) { self.request = request }

    private func run() async throws -> (URL, URLResponse) {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let resumeData = try? Data(contentsOf: request.resumeFile)
                let task = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: request.url)
                let cancelNow = lock.withLock {
                    self.continuation = continuation
                    self.task = task
                    return wasCancelled
                }
                task.resume()
                if cancelNow { cancelTask() }
            }
        } onCancel: {
            cancelTask()
        }
    }

    private func cancelTask() {
        let task = lock.withLock { wasCancelled = true; return self.task }
        task?.cancel { [resumeFile = request.resumeFile] data in
            if let data { try? data.write(to: resumeFile, options: .atomic) }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
        request.onBytes(fileOffset)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        request.onBytes(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // location 은 이 함수가 끝나면 사라지므로 바로 옮깁니다.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("condux-model-\(UUID().uuidString)")
        guard (try? FileManager.default.moveItem(at: location, to: kept)) != nil, let response = downloadTask.response else { return }
        lock.withLock { result = (kept, response) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let data = (error as NSError?)?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            try? data.write(to: request.resumeFile, options: .atomic)
        }
        let (continuation, result, cancelled): (CheckedContinuation<(URL, URLResponse), Error>?, (URL, URLResponse)?, Bool) = lock.withLock {
            defer { self.continuation = nil }
            return (self.continuation, self.result, wasCancelled)
        }
        if let error {
            continuation?.resume(throwing: cancelled ? CancellationError() : error)
        } else if let result {
            continuation?.resume(returning: result)
        } else {
            continuation?.resume(throwing: LocalLLMError.downloadFailed)
        }
    }
}

protocol LocalLLMGenerating {
    var isAvailable: Bool { get }
    func stream(directory: URL, history: [LocalLLMMessage], prompt: String,
                onDelta: @MainActor @Sendable (String) -> Void) async throws
}

/// 테스트는 가짜 엔진을 주입합니다. 실제 MLX와 Metal은 직접 설치판 Xcode 빌드에서만 연결합니다.
struct MLXLocalLLMClient: LocalLLMGenerating {
    var isAvailable: Bool {
        #if canImport(MLXLLM) && !CONDUX_APPSTORE && arch(arm64)
        return true
        #else
        return false
        #endif
    }

    func stream(directory: URL, history: [LocalLLMMessage], prompt: String,
                onDelta: @MainActor @Sendable (String) -> Void) async throws {
        guard history.reduce(prompt.count, { $0 + $1.text.count }) <= 8_000 else { throw LocalLLMError.contextTooLong }
        try Task.checkCancellation()
        #if canImport(MLXLLM) && !CONDUX_APPSTORE && arch(arm64)
        // local directory configuration never downloads model weights or sends the conversation.
        defer { Memory.clearCache() }
        try await generate(directory: directory, history: history, prompt: prompt, onDelta: onDelta)
        #else
        throw LocalLLMError.unavailable
        #endif
    }

    #if canImport(MLXLLM) && !CONDUX_APPSTORE && arch(arm64)
    private func generate(directory: URL, history: [LocalLLMMessage], prompt: String,
                          onDelta: @MainActor @Sendable (String) -> Void) async throws {
        let hub = HubApi(downloadBase: directory.deletingLastPathComponent(), cache: nil,
                         hfToken: "", useOfflineMode: true)
        let container = try await LLMModelFactory.shared.loadContainer(hub: hub, configuration: .init(directory: directory))
        try Task.checkCancellation()
        let messages = history.map { Chat.Message(role: $0.role == .user ? .user : .assistant, content: $0.text) }
        let session = ChatSession(container, instructions: "사용자가 쓴 언어로 간결하게 답하세요. 도구나 파일에 접근할 수 없습니다.",
                                  history: messages, generateParameters: GenerateParameters(maxTokens: 512, temperature: 0.7, topP: 0.8, topK: 20),
                                  additionalContext: ["enable_thinking": false])
        for try await chunk in session.streamResponse(to: prompt) {
            try Task.checkCancellation()
            await onDelta(chunk)
        }
        try Task.checkCancellation()
    }
    #endif
}
