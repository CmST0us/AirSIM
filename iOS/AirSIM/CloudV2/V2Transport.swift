import Foundation

struct V2HTTPResponse { let status: Int; let body: Data }
protocol V2HTTPTransport { func send(_ request: URLRequest, limit: Int) async throws -> V2HTTPResponse }
struct V2HTTPFailure: Error { let status: Int }

struct V2URLSessionTransport: V2HTTPTransport {
    // Explicit test-only URLProtocol injection; production reuses a shared
    // ephemeral URLSession for HTTP/2 + TLS keep-alive pooling.
    var protocolClasses: [AnyClass]? = nil
    private let customSession: V2SharedSession?

    init(protocolClasses: [AnyClass]? = nil) {
        self.protocolClasses = protocolClasses
        self.customSession = protocolClasses.map { V2SharedSession(protocolClasses: $0) }
    }

    func send(_ request: URLRequest, limit: Int) async throws -> V2HTTPResponse {
        guard let url = request.url, url.scheme == "https", url.user == nil, url.password == nil,
              limit > 0 else { throw V2Error.invalidValue }
        let pool = customSession ?? V2SharedSession.production
        return try await pool.send(request, limit: limit)
    }
}

private final class V2TaskState {
    let limit: Int
    var body = Data()
    var status: Int?
    var continuation: CheckedContinuation<V2HTTPResponse, Error>?
    var task: URLSessionDataTask?
    var finished = false
    init(limit: Int) { self.limit = limit }
}

// Reuses one ephemeral URLSession (no disk cache, no cookies, no proxies,
// TLS 1.2+) across requests so polling and call-setup share persistent HTTP/2
// connections instead of doing a fresh TCP+TLS handshake per request.
private final class V2SharedSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let production = V2SharedSession(protocolClasses: nil)

    private let lock = NSLock()
    private var states: [Int: V2TaskState] = [:]
    private var session: URLSession!

    init(protocolClasses: [AnyClass]?) {
        super.init()
        let config = URLSessionConfiguration.ephemeral
        if let protocolClasses { config.protocolClasses = protocolClasses }
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0, "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0]
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        config.httpMaximumConnectionsPerHost = 6
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }

    deinit {
        session?.finishTasksAndInvalidate()
    }

    func send(_ request: URLRequest, limit: Int) async throws -> V2HTTPResponse {
        let state = V2TaskState(limit: limit)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if state.finished {
                    lock.unlock()
                    continuation.resume(throwing: V2Error.transport)
                    return
                }
                state.continuation = continuation
                let task = session.dataTask(with: request)
                state.task = task
                states[task.taskIdentifier] = state
                lock.unlock()
                task.resume()
            }
        }, onCancel: {
            finish(state: state, result: .failure(V2Error.transport), cancelTask: true)
        })
    }

    private func finish(taskID: Int, result: Result<V2HTTPResponse, Error>, cancelTask: Bool) {
        lock.lock()
        guard let state = states.removeValue(forKey: taskID) else { lock.unlock(); return }
        if state.finished { lock.unlock(); return }
        state.finished = true
        let completion = state.continuation; state.continuation = nil
        let task = state.task; state.task = nil
        lock.unlock()
        if cancelTask { task?.cancel() }
        completion?.resume(with: result)
    }

    private func finish(state: V2TaskState, result: Result<V2HTTPResponse, Error>, cancelTask: Bool) {
        lock.lock()
        if state.finished { lock.unlock(); return }
        state.finished = true
        let completion = state.continuation; state.continuation = nil
        let task = state.task; state.task = nil
        if let task { states.removeValue(forKey: task.taskIdentifier) }
        lock.unlock()
        if cancelTask { task?.cancel() }
        completion?.resume(with: result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(taskID: task.taskIdentifier, result: .failure(V2Error.redirect), cancelTask: true)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(taskID: dataTask.taskIdentifier, result: .failure(V2Error.transport), cancelTask: false)
            return
        }
        lock.lock()
        guard let state = states[dataTask.taskIdentifier], !state.finished else {
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        guard response.expectedContentLength <= Int64(state.limit) else {
            lock.unlock()
            completionHandler(.cancel)
            finish(taskID: dataTask.taskIdentifier, result: .failure(V2Error.oversized), cancelTask: false)
            return
        }
        state.status = response.statusCode
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard let state = states[dataTask.taskIdentifier], !state.finished else { lock.unlock(); return }
        guard data.count <= state.limit - state.body.count else {
            lock.unlock()
            finish(taskID: dataTask.taskIdentifier, result: .failure(V2Error.oversized), cancelTask: true)
            return
        }
        state.body.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard let state = states[task.taskIdentifier] else { lock.unlock(); return }
        let status = state.status
        let body = state.body
        lock.unlock()
        guard error == nil, let status else {
            finish(taskID: task.taskIdentifier, result: .failure(V2Error.transport), cancelTask: false)
            return
        }
        finish(taskID: task.taskIdentifier, result: .success(V2HTTPResponse(status: status, body: body)), cancelTask: false)
    }
}
