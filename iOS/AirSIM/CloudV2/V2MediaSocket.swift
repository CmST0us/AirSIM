import Foundation

@MainActor
protocol V2MediaSocket: AnyObject {
    func open(_ url: URL) async throws -> String?
    func limit(_ bytes: Int)
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func cancel()
}

// Every pending continuation is explicitly resumed on cancel. Delegate callbacks
// carry a task identity and can only finish their own operation.
@MainActor
final class V2URLMediaSocket: NSObject, V2MediaSocket, URLSessionWebSocketDelegate {
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var opening: CheckedContinuation<String?, Error>?
    private var writing: CheckedContinuation<Void, Error>?
    private var reading: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    func open(_ url: URL) async throws -> String? {
        guard socket == nil, url.scheme == "wss", url.query == nil, url.fragment == nil, url.user == nil else { throw V2Error.invalidValue }
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]; config.urlCache = nil
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        let socket = session.webSocketTask(with: url, protocols: ["airsim.media.v2"])
        self.socket = socket; socket.maximumMessageSize = 2048
        return try await withCheckedThrowingContinuation { opening = $0; socket.resume() }
    }
    func limit(_ bytes: Int) { socket?.maximumMessageSize = bytes }
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        guard let socket, writing == nil else { throw V2Error.busy }
        try await withCheckedThrowingContinuation { continuation in
            writing = continuation
            socket.send(message) { [weak self, weak socket] error in
                Task { @MainActor in
                    guard let self, let socket, self.socket === socket, let pending = self.writing else { return }
                    self.writing = nil
                    if let error {
#if DEBUG
                        self.logSocket(event: "socketSendFailure", task: socket, error: error)
#endif
                        pending.resume(throwing: error)
                    } else { pending.resume() }
                }
            }
        }
    }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        guard let socket, reading == nil else { throw V2Error.busy }
        return try await withCheckedThrowingContinuation { continuation in
            reading = continuation
            socket.receive { [weak self, weak socket] result in
                Task { @MainActor in
                    guard let self, let socket, self.socket === socket, let pending = self.reading else { return }
#if DEBUG
                    if case .failure(let error) = result { self.logSocket(event: "socketReceiveFailure", task: socket, error: error) }
#endif
                    self.reading = nil; pending.resume(with: result)
                }
            }
        }
    }
    func cancel() {
#if DEBUG
        if let socket { logSocket(event: "socketLocalCancel", task: socket, error: nil) }
#endif
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        session?.invalidateAndCancel(); session = nil
        let open = opening, write = writing, read = reading
        opening = nil; writing = nil; reading = nil
        open?.resume(throwing: CancellationError()); write?.resume(throwing: CancellationError()); read?.resume(throwing: CancellationError())
    }
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        Task { @MainActor in
            guard socket === webSocketTask else { return }
            let pending = opening; opening = nil; pending?.resume(returning: `protocol`)
        }
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        Task { @MainActor in
#if DEBUG
            logSocket(event: "socketCompleted", task: task, error: error)
#endif
            if socket === task { cancel() }
        }
    }
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Task { @MainActor in
#if DEBUG
            NSLog("[AirSIM Media] stage=socketClosed current=%d closeCode=%ld taskState=%ld", socket === webSocketTask ? 1 : 0, closeCode.rawValue, webSocketTask.state.rawValue)
#endif
            if socket === webSocketTask { cancel() }
        }
    }
#if DEBUG
    private func logSocket(event: String, task: URLSessionTask, error: Error?) {
        let failure = error.map { V2MediaFailureDiagnostic(error: $0, stage: .receiving, downlinkAgeMilliseconds: nil) }
        let closeCode = (task as? URLSessionWebSocketTask)?.closeCode.rawValue ?? 0
        NSLog("[AirSIM Media] stage=%@ current=%d taskState=%ld closeCode=%ld errorPresent=%d code=%@ numericPresent=%d numeric=%ld", event, socket === task ? 1 : 0, task.state.rawValue, closeCode, error != nil ? 1 : 0, failure?.code.rawValue ?? "none", failure?.numericCode != nil ? 1 : 0, failure?.numericCode ?? 0)
    }
#endif
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor
protocol V2MediaClock {
    var now: UInt64 { get }
    func sleep(until: UInt64) async throws
}
struct V2SystemMediaClock: V2MediaClock {
    var now: UInt64 { DispatchTime.now().uptimeNanoseconds }
    func sleep(until: UInt64) async throws {
        let current = now
        if until > current { try await Task.sleep(nanoseconds: until - current) }
        try Task.checkCancellation()
    }
}

// First completion wins. Timeout closes the transport, which releases its pending
// operation, instead of waiting for a cooperative cancellation of a task group.
@MainActor
final class V2MediaDeadline<Value> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var worker: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    func run(clock: V2MediaClock, until: UInt64, cancel: @escaping () -> Void, operation: @escaping () async throws -> Value) async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                worker = Task {
                    do {
                        let value = try await operation()
                        if clock.now >= until { cancel(); self.finish(.failure(V2MediaFailure.timeout)) }
                        else { self.finish(.success(value)) }
                    } catch {
                        if clock.now >= until { cancel(); self.finish(.failure(V2MediaFailure.timeout)) }
                        else { self.finish(.failure(error)) }
                    }
                }
                timer = Task {
                    do { try await clock.sleep(until: until) } catch { return }
                    cancel(); self.finish(.failure(V2MediaFailure.timeout))
                }
                if Task.isCancelled { cancel(); finish(.failure(CancellationError())) }
            }
        } onCancel: { Task { @MainActor in cancel(); self.finish(.failure(CancellationError())) } }
    }
    private func finish(_ result: Result<Value, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        worker?.cancel(); timer?.cancel(); worker = nil; timer = nil
        continuation.resume(with: result)
    }
}

enum V2MediaFailure: Error { case timeout, handshake, stale, inactive, inputStopped, downlinkStopped, disconnected }
