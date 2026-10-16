import Foundation
import Darwin

enum ContinueStateWatcher {
    struct Options { let url: URL; let duration: TimeInterval; let interval: TimeInterval; let session: String? }
    enum WatchError: Error { case invalidOptions, invalidEndpoint, timeout, invalidResponse, oversizedResponse, network }

    static func endpoint(_ value: String) throws -> URL {
        guard var parts = URLComponents(string: value), parts.scheme == "http",
              ["127.0.0.1", "::1", "[::1]"].contains(parts.host ?? ""),
              let port = parts.port, (1...65535).contains(port), parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, ["", "/", "/state"].contains(parts.path) else { throw WatchError.invalidEndpoint }
        parts.path = "/state"
        guard let url = parts.url else { throw WatchError.invalidEndpoint }
        return url
    }

    static func options(_ arguments: [String]) throws -> Options {
        var values: [String: String] = [:]
        guard arguments.count % 2 == 0 else { throw WatchError.invalidOptions }
        for index in stride(from: 0, to: arguments.count, by: 2) {
            let key = arguments[index]
            guard ["--url", "--duration", "--interval", "--session"].contains(key), values[key] == nil else { throw WatchError.invalidOptions }
            values[key] = arguments[index + 1]
        }
        guard let raw = values["--url"], let duration = Double(values["--duration"] ?? "300"),
              let interval = Double(values["--interval"] ?? "1"), duration.isFinite, interval.isFinite,
              (1...3600).contains(duration), (0.2...60).contains(interval) else { throw WatchError.invalidOptions }
        if let id = values["--session"], id.isEmpty || id.utf8.contains(0) || id.utf8.count > 4096 { throw WatchError.invalidOptions }
        return Options(url: try endpoint(raw), duration: duration, interval: interval, session: values["--session"])
    }

    static func run(arguments: [String]) -> Int32 {
        do {
            let options = try options(arguments)
            let observer = ContinueStateObserver(expectedSessionID: options.session)
            let socket = DIBridge.socketPath()
            let deadline = ProcessInfo.processInfo.systemUptime + options.duration
            fputs("[XIsland] 仅观察指定 cn serve；GET /state 会延长服务存活。本次观察限时 \(Int(options.duration)) 秒，不启动或关闭服务。\n", stderr)
            defer { if let ended = observer.disconnected() { ObservationSender.send(ended, socketPath: socket) } }
            while ProcessInfo.processInfo.systemUptime < deadline {
                let start = ProcessInfo.processInfo.systemUptime
                let data = try fetch(options.url)
                for message in try observer.consume(data) { ObservationSender.send(message, socketPath: socket) }
                let remaining = min(options.interval - (ProcessInfo.processInfo.systemUptime - start), deadline - ProcessInfo.processInfo.systemUptime)
                if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
            }
            return 0
        } catch {
            fputs("[XIsland] Continue 观察停止：端点、会话身份或响应未通过验证。未发送控制请求。\n", stderr)
            return 1
        }
    }

    static func fetch(_ url: URL, timeout: TimeInterval = 2) throws -> Data {
        _ = try endpoint(url.absoluteString)
        guard timeout.isFinite, timeout > 0 else { throw WatchError.invalidOptions }
        let loader = Loader()
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.urlCredentialStorage = nil; config.httpCookieStorage = nil
        config.httpShouldSetCookies = false; config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = timeout; config.timeoutIntervalForResource = timeout
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: loader, delegateQueue: queue)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let task = session.dataTask(with: request); task.resume()
        if loader.finished.wait(timeout: .now() + timeout + 0.25) != .success {
            task.cancel(); throw WatchError.timeout
        }
        return try loader.result()
    }

    private final class Loader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let finished = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var bytes = Data()
        private var completion: Result<Data, Error>?
        private func finish(_ error: Error?) {
            lock.lock(); defer { lock.unlock() }
            guard completion == nil else { return }
            completion = error.map { .failure($0) } ?? .success(bytes)
            finished.signal()
        }
        func result() throws -> Data {
            lock.lock(); defer { lock.unlock() }
            return try (completion ?? .failure(WatchError.network)).get()
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  response.mimeType == "application/json" else {
                finish(WatchError.invalidResponse); completionHandler(.cancel); return
            }
            guard response.expectedContentLength <= 2_097_152 else {
                finish(WatchError.oversizedResponse); completionHandler(.cancel); return
            }
            completionHandler(.allow)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock()
            guard completion == nil else { lock.unlock(); return }
            let tooLarge = bytes.count + data.count > 2_097_152
            if !tooLarge { bytes.append(data) }
            lock.unlock()
            if tooLarge { finish(WatchError.oversizedResponse); dataTask.cancel() }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { finish(error) }
    }
}
