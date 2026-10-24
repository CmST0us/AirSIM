import Foundation

struct V2HTTPResponse { let status: Int; let body: Data }
protocol V2HTTPTransport { func send(_ request: URLRequest, limit: Int) async throws -> V2HTTPResponse }
struct V2HTTPFailure: Error { let status: Int }

struct V2URLSessionTransport: V2HTTPTransport {
    // Explicit test-only URLProtocol injection; production uses the default nil.
    var protocolClasses: [AnyClass]? = nil
    func send(_ request: URLRequest, limit: Int) async throws -> V2HTTPResponse {
        guard let url = request.url, url.scheme == "https", url.user == nil, url.password == nil,
              limit > 0 else { throw V2Error.invalidValue }
        let operation = V2HTTPOperation(limit: limit, protocolClasses: protocolClasses)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { operation.start(request, continuation: $0) }
        }, onCancel: { operation.cancel() })
    }
}

// One bounded operation and serial delegate queue per request. Cancellation before
// continuation installation and cancellation after headers both finish exactly once.
private final class V2HTTPOperation: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private let protocolClasses: [AnyClass]?
    private var body = Data()
    private var status: Int?
    private var continuation: CheckedContinuation<V2HTTPResponse, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var finished = false
    init(limit: Int, protocolClasses: [AnyClass]?) { self.limit = limit; self.protocolClasses = protocolClasses }
    func start(_ request: URLRequest, continuation: CheckedContinuation<V2HTTPResponse, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); continuation.resume(throwing: V2Error.transport); return }
        self.continuation = continuation
        let config = URLSessionConfiguration.ephemeral
        if let protocolClasses { config.protocolClasses = protocolClasses }
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0, "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0]
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        config.timeoutIntervalForRequest = 5; config.timeoutIntervalForResource = 5
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        self.session = session
        task = session.dataTask(with: request)
        task?.resume()
        lock.unlock()
    }
    func cancel() { finish(.failure(V2Error.transport)) }
    private func finish(_ result: Result<V2HTTPResponse, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let completion = continuation; continuation = nil
        let session = self.session; self.session = nil; task = nil
        lock.unlock()
        session?.invalidateAndCancel(); completion?.resume(with: result)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil); finish(.failure(V2Error.redirect))
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else { completionHandler(.cancel); finish(.failure(V2Error.transport)); return }
        guard response.expectedContentLength <= Int64(limit) else { completionHandler(.cancel); finish(.failure(V2Error.oversized)); return }
        status = response.statusCode; completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard data.count <= limit - body.count else { finish(.failure(V2Error.oversized)); return }
        body.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard error == nil, let status else { finish(.failure(V2Error.transport)); return }
        finish(.success(V2HTTPResponse(status: status, body: body)))
    }
}
