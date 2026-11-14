import Foundation

/// Uploads files through a background URLSession: iOS keeps sending them while the app is
/// suspended or even terminated, and relaunches the app to report results (docs/05-sync.md §3).
final class BackgroundUploader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let identifier = "day.zone2.app.upload"

    /// (taskDescription = workout uuid, HTTP status or 0, response body, error)
    typealias Completion = @Sendable (String, Int, Data, Error?) -> Void

    private let lock = NSLock()
    private var bodies: [Int: Data] = [:]
    private var onComplete: Completion?
    private var finishEvents: [CheckedContinuation<Void, Never>] = []

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    func start(onComplete: @escaping Completion) {
        lock.withLock { self.onComplete = onComplete }
        _ = session // reconnects to tasks that ran while the app was gone
    }

    func enqueue(file: URL, uuid: String, url: URL, token: String) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/gzip", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let task = session.uploadTask(with: request, fromFile: file)
        task.taskDescription = uuid
        task.resume()
    }

    func inFlight() async -> Set<String> {
        Set(await session.allTasks.compactMap(\.taskDescription))
    }

    /// For `.backgroundTask(.urlSession)`: returns when iOS finished delivering this session's events.
    func waitForEvents() async {
        _ = session
        await withCheckedContinuation { cont in lock.withLock { finishEvents.append(cont) } }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { bodies[dataTask.taskIdentifier, default: Data()].append(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let body = lock.withLock { bodies.removeValue(forKey: task.taskIdentifier) ?? Data() }
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let callback = lock.withLock { onComplete }
        callback?(task.taskDescription ?? "", status, body, error)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            defer { finishEvents = [] }
            return finishEvents
        }
        waiting.forEach { $0.resume() }
    }
}
