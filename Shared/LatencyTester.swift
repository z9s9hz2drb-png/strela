import Foundation
import Network
import Security

/// Latency measurement through local Xray HTTP inbounds (Proxy GET / HEAD) or plain TCP connect.
enum LatencyTester {
    /// Full request time of `method url` sent through the HTTP proxy on 127.0.0.1:`port`. -1 on failure.
    static func http(port: Int, url: URL, method: String, timeout: TimeInterval) async -> Int {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": port,
            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": port,
        ]
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode < 500 else { return -1 }
            return max(1, Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000))
        } catch {
            return -1
        }
    }

    /// Time to establish a TCP connection to host:port. -1 on failure.
    static func tcp(host: String, port: Int, timeout: TimeInterval) async -> Int {
        guard !host.isEmpty, let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return -1 }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let start = DispatchTime.now().uptimeNanoseconds
        let queue = DispatchQueue(label: "strela.tcpping")
        let once = OnceFlag()
        return await withCheckedContinuation { continuation in
            let finish: (Int) -> Void = { value in
                guard once.claim() else { return }
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(max(1, Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)))
                case .failed, .waiting, .cancelled:
                    finish(-1)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(-1) }
        }
    }

    struct HTTPJob {
        var id: UUID
        var port: Int
    }

    /// Download throughput (Mbit/s) through the HTTP proxy on 127.0.0.1:`port`.
    /// Counts bytes from the first received byte for `seconds` (or until the file ends). -1 on failure.
    static func throughput(port: Int, url: URL, seconds: TimeInterval, connectTimeout: TimeInterval) async -> Double {
        await withCheckedContinuation { continuation in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.connectionProxyDictionary = [
                "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": port,
                "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": port,
            ]
            configuration.timeoutIntervalForRequest = connectTimeout
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.urlCache = nil
            let probe = SpeedProbe(seconds: seconds, continuation: continuation)
            let session = URLSession(configuration: configuration, delegate: probe, delegateQueue: nil)
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: connectTimeout)
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            probe.start(session: session, task: session.dataTask(with: request), deadline: connectTimeout + seconds)
        }
    }

    /// Upload throughput (Mbit/s): POSTs `bytes` of random data through the HTTP proxy on 127.0.0.1:`port`.
    /// Measured from the first sent byte until the server answers (it has received everything) or
    /// until `seconds` pass. -1 on failure.
    static func uploadThroughput(port: Int, url: URL, bytes: Int, seconds: TimeInterval,
                                 connectTimeout: TimeInterval) async -> Double {
        var body = Data(count: max(256 * 1024, bytes))
        let count = body.count
        let status = body.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        if status != errSecSuccess {
            body = Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 2654435761 >> 13) })
        }
        let payload = body
        return await withCheckedContinuation { continuation in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.connectionProxyDictionary = [
                "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": port,
                "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": port,
            ]
            configuration.timeoutIntervalForRequest = connectTimeout + seconds
            configuration.urlCache = nil
            let probe = UploadProbe(seconds: seconds, continuation: continuation)
            let session = URLSession(configuration: configuration, delegate: probe, delegateQueue: nil)
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                     timeoutInterval: connectTimeout + seconds)
            request.httpMethod = "POST"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            probe.start(session: session, task: session.uploadTask(with: request, from: payload),
                        deadline: connectTimeout + seconds)
        }
    }

    static func uploadSequential(_ jobs: [HTTPJob], url: URL, bytes: Int, seconds: TimeInterval,
                                 connectTimeout: TimeInterval) async -> [UUID: Double] {
        var results: [UUID: Double] = [:]
        for job in jobs {
            results[job.id] = await uploadThroughput(port: job.port, url: url, bytes: bytes,
                                                     seconds: seconds, connectTimeout: connectTimeout)
        }
        return results
    }

    /// One server at a time: parallel downloads would compete for the same link.
    static func throughputSequential(_ jobs: [HTTPJob], url: URL, seconds: TimeInterval,
                                     connectTimeout: TimeInterval) async -> [UUID: Double] {
        var results: [UUID: Double] = [:]
        for job in jobs {
            results[job.id] = await throughput(port: job.port, url: url, seconds: seconds, connectTimeout: connectTimeout)
        }
        return results
    }

    struct TCPJob {
        var id: UUID
        var host: String
        var port: Int
    }

    static func httpBatch(_ jobs: [HTTPJob], url: URL, method: String, timeout: TimeInterval, concurrency: Int) async -> [UUID: Int] {
        await limited(jobs, concurrency: concurrency) { job in
            (job.id, await http(port: job.port, url: url, method: method, timeout: timeout))
        }
    }

    static func tcpBatch(_ jobs: [TCPJob], timeout: TimeInterval, concurrency: Int) async -> [UUID: Int] {
        await limited(jobs, concurrency: concurrency) { job in
            (job.id, await tcp(host: job.host, port: job.port, timeout: timeout))
        }
    }

    private static func limited<Job>(_ jobs: [Job], concurrency: Int, _ work: @escaping (Job) async -> (UUID, Int)) async -> [UUID: Int] {
        var results: [UUID: Int] = [:]
        await withTaskGroup(of: (UUID, Int).self) { group in
            var iterator = jobs.makeIterator()
            for _ in 0..<max(1, concurrency) {
                guard let job = iterator.next() else { break }
                group.addTask { await work(job) }
            }
            while let (id, value) = await group.next() {
                results[id] = value
                if let job = iterator.next() {
                    group.addTask { await work(job) }
                }
            }
        }
        return results
    }
}

/// URLSession delegate that counts received bytes and discards the data (no memory growth).
final class SpeedProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let seconds: TimeInterval
    private var continuation: CheckedContinuation<Double, Never>?
    private var session: URLSession?
    private var received: Int64 = 0
    private var firstByte: UInt64 = 0
    private var finished = false

    init(seconds: TimeInterval, continuation: CheckedContinuation<Double, Never>) {
        self.seconds = seconds
        self.continuation = continuation
    }

    func start(session: URLSession, task: URLSessionDataTask, deadline: TimeInterval) {
        lock.lock()
        self.session = session
        lock.unlock()
        task.resume()
        DispatchQueue.global().asyncAfter(deadline: .now() + deadline) { [weak self] in self?.finish() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            completionHandler(.cancel)
            finish(failed: true)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let isFirst = firstByte == 0
        if isFirst { firstByte = DispatchTime.now().uptimeNanoseconds }
        received += Int64(data.count)
        lock.unlock()
        if isFirst {
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in self?.finish() }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish()
    }

    private func finish(failed: Bool = false) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let bytes = received
        let first = firstByte
        let session = self.session
        let continuation = self.continuation
        self.session = nil
        self.continuation = nil
        lock.unlock()

        session?.invalidateAndCancel()
        let elapsed = first == 0 ? 0 : Double(DispatchTime.now().uptimeNanoseconds - first) / 1_000_000_000
        var mbps = -1.0
        if !failed, bytes >= 256 * 1024, elapsed > 0.2 {
            mbps = Double(bytes) * 8 / elapsed / 1_000_000
        }
        continuation?.resume(returning: mbps)
    }
}

/// Tracks how many body bytes were sent; the server's response marks the moment it got them all.
final class UploadProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let seconds: TimeInterval
    private var continuation: CheckedContinuation<Double, Never>?
    private var session: URLSession?
    private var sent: Int64 = 0
    private var firstSend: UInt64 = 0
    private var finished = false

    init(seconds: TimeInterval, continuation: CheckedContinuation<Double, Never>) {
        self.seconds = seconds
        self.continuation = continuation
    }

    func start(session: URLSession, task: URLSessionTask, deadline: TimeInterval) {
        lock.lock()
        self.session = session
        lock.unlock()
        task.resume()
        DispatchQueue.global().asyncAfter(deadline: .now() + deadline) { [weak self] in self?.finish() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        lock.lock()
        let isFirst = firstSend == 0
        if isFirst { firstSend = DispatchTime.now().uptimeNanoseconds }
        sent = totalBytesSent
        lock.unlock()
        if isFirst {
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in self?.finish() }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let failed = (response as? HTTPURLResponse).map { $0.statusCode >= 400 } ?? false
        completionHandler(.cancel)
        finish(failed: failed)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish()
    }

    private func finish(failed: Bool = false) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let bytes = sent
        let first = firstSend
        let session = self.session
        let continuation = self.continuation
        self.session = nil
        self.continuation = nil
        lock.unlock()

        session?.invalidateAndCancel()
        let elapsed = first == 0 ? 0 : Double(DispatchTime.now().uptimeNanoseconds - first) / 1_000_000_000
        var mbps = -1.0
        if !failed, bytes >= 256 * 1024, elapsed > 0.2 {
            mbps = Double(bytes) * 8 / elapsed / 1_000_000
        }
        continuation?.resume(returning: mbps)
    }
}

/// Thread-safe "first caller wins" flag.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// Thread-safe dictionary box for callbacks running on several queues.
final class LockedDictionary<Key: Hashable, Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Key: Value] = [:]

    subscript(key: Key) -> Value? {
        get { lock.lock(); defer { lock.unlock() }; return storage[key] }
        set { lock.lock(); storage[key] = newValue; lock.unlock() }
    }

    var snapshot: [Key: Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

// MARK: - App ↔ extension messages

enum IPCCommand: String, Codable {
    case status
    case ping
    case reload
    case logs
    case speed
}

struct SpeedRequest: Codable {
    var serverIDs: [UUID]
    var url: String
    var seconds: Int
    /// true = upload ("передача"): POST `uploadBytes` to `url`.
    var upload: Bool
    var uploadBytes: Int
}

struct SpeedResponse: Codable {
    /// Server id (uuidString) → Mbit/s (-1 = failed).
    var results: [String: Double]
}

struct PingRequest: Codable {
    var serverIDs: [UUID]
    var type: PingType
    var url: String
    var timeout: Int
    var concurrency: Int
}

struct IPCRequest: Codable {
    var command: IPCCommand
    var ping: PingRequest? = nil
    /// New plan for `reload` (the extension may not see the App Group file after re-signing).
    var plan: TunnelPlan? = nil
    var speed: SpeedRequest? = nil
}

struct PingResponse: Codable {
    /// Server id (uuidString) → milliseconds (-1 = failed).
    var results: [String: Int]
}

struct ObservedOutbound: Codable, Hashable {
    var alive: Bool
    var delay: Int64
}

struct TunnelStatus: Codable {
    var uplink: Int64 = 0
    var downlink: Int64 = 0
    var proxyUplink: Int64 = 0
    var proxyDownlink: Int64 = 0
    var directUplink: Int64 = 0
    var directDownlink: Int64 = 0
    var observatory: [String: ObservedOutbound] = [:]
    var title = ""
    var autoTags: [String] = []
    var tagNames: [String: String] = [:]
    var priorityAuto = false

    /// What the balancer currently picks: in speed mode the first alive candidate in speed order,
    /// otherwise (leastPing) the alive candidate with the lowest delay.
    var activeAutoTag: String? {
        if priorityAuto {
            return autoTags.first { tag in
                guard let observed = observatory[tag] else { return false }
                return observed.alive && observed.delay < 3000
            }
        }
        var best: (tag: String, delay: Int64)?
        for tag in autoTags {
            guard let observed = observatory[tag], observed.alive else { continue }
            if best == nil || observed.delay < best!.delay { best = (tag, observed.delay) }
        }
        return best?.tag
    }

    /// Parses Xray's metrics endpoint (`/debug/vars`): traffic counters and observatory results.
    mutating func applyMetrics(_ data: Data) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject else { return }
        if let stats = root["stats"] as? JSONObject {
            if let inbound = stats["inbound"] as? JSONObject, let tun = inbound["tun-in"] as? JSONObject {
                uplink = Int64(JSONUtil.int(tun["uplink"]) ?? 0)
                downlink = Int64(JSONUtil.int(tun["downlink"]) ?? 0)
            }
            if let outbound = stats["outbound"] as? JSONObject {
                proxyUplink = 0; proxyDownlink = 0; directUplink = 0; directDownlink = 0
                for (tag, value) in outbound {
                    guard let counters = value as? JSONObject else { continue }
                    let up = Int64(JSONUtil.int(counters["uplink"]) ?? 0)
                    let down = Int64(JSONUtil.int(counters["downlink"]) ?? 0)
                    if tag == "direct" {
                        directUplink += up; directDownlink += down
                    } else if tag == "proxy" || tag.hasPrefix("auto-") {
                        proxyUplink += up; proxyDownlink += down
                    }
                }
            }
        }
        if let observed = root["observatory"] as? JSONObject {
            var result: [String: ObservedOutbound] = [:]
            for (tag, value) in observed {
                guard let item = value as? JSONObject else { continue }
                result[tag] = ObservedOutbound(alive: (item["alive"] as? Bool) ?? false,
                                               delay: Int64(JSONUtil.int(item["delay"]) ?? 0))
            }
            observatory = result
        }
    }
}
