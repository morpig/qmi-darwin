import Foundation
import QMIDAPI
import QMIKit

// Keeping the modem's XTRA data fresh. The modem has not been seen fetching it by itself
// under qmid, so qmid downloads the file (XTRADownload.servers) and loads it
// (GNSSAssist.load) once the data is older than maxAge, or missing / unreadable. The download
// goes over the Mac's default route. See docs/API.md, "GNSS assistance (XTRA)".
//
// XTRAUpdater decides; Manager runs a check on its GNSS queue (check) and applies the outcome
// on its own (apply). The modem and the network are passed in, so both can be tested.
enum XTRAUpdater {
    enum Outcome: Equatable {
        case unsupported
        case notDue(Date)
        case loaded(QMIDXTRA, lastModified: String?, from: String)
        case notNewer(String)
        case failed(String)
    }

    // One check: what the modem holds; if a load is due, download and load. Blocks.
    static func check(state st: XTRAState, maxAge: TimeInterval, configured: [String]?, now: Date = Date(),
                      snapshot: () throws -> GNSSAssist.Snapshot,
                      fetch: (_ servers: [String], _ since: String?) throws -> XTRADownload.Result,
                      load: ([UInt8]) throws -> QMIDXTRA) -> Outcome {
        do {
            let snap = try snapshot()
            guard snap.supported else { return .unsupported }
            let due = XTRASchedule.loadDue(validFrom: snap.validity?.start, unreadable: snap.unreadable, now: now,
                                           maxAge: maxAge, notBefore: st.notBefore)
            guard due <= now else { return .notDue(due) }
            // Without usable data, any file will do: no If-Modified-Since.
            let since = snap.validity == nil ? nil : st.lastModified
            switch try fetch(XTRADownload.servers(configured: configured, modem: snap.servers), since) {
            case .notModified(let host):
                return .notNewer("not modified on \(host)")
            case .file(let bytes, let lm, let host):
                if !snap.unreadable, !XTRASchedule.isNewer(lastModified: lm.flatMap(XTRASchedule.httpDate), than: snap.validity?.start) {
                    return .notNewer("\(host) has nothing newer (\(lm ?? "?"))")
                }
                return .loaded(try load(bytes), lastModified: lm, from: host)
            }
        } catch {
            return .failed("\(error)")
        }
    }

    // What an outcome does to the state; when to check next (nil: never) and what to log.
    static func apply(_ outcome: Outcome, to state: inout XTRAState, now: Date, maxAge: TimeInterval)
        -> (next: Date?, log: (level: QMIDLogLevel, message: String)?) {
        switch outcome {
        case .unsupported:
            return (nil, (.info, "XTRA: not supported by this modem; no updates"))
        case .notDue(let due):
            return (XTRASchedule.nextCheck(due: due, now: now), nil)
        case .loaded(let x, let lm, let host):
            state.lastModified = lm
            state.lastDownload = now
            state.failures = 0
            state.lastError = nil
            state.notBefore = nil
            return (XTRASchedule.nextCheck(due: x.validFrom.map { $0.addingTimeInterval(maxAge) } ?? now, now: now),
                    (.notice, "XTRA: updated from \(host)"))
        case .notNewer(let why):
            state.notBefore = now.addingTimeInterval(XTRASchedule.notNewerDelay)
            return (state.notBefore, (.info, "XTRA: \(why); asking again in 1 h"))
        case .failed(let e):
            state.failures += 1
            state.lastError = e
            let delay = XTRASchedule.retryDelay(failures: state.failures)
            state.notBefore = now.addingTimeInterval(delay)
            return (state.notBefore,
                    (.error, "XTRA: update failed (\(state.failures) in a row): \(e); again in \(Int(delay / 60)) min"))
        }
    }
}

// When to load and when to look again; pure, so it can be tested with made-up times.
enum XTRASchedule {
    static let checkInterval: TimeInterval = 6 * 3600   // look at least this often
    static let notNewerDelay: TimeInterval = 3600       // the server had nothing newer: ask again then
    static let retryDelays: [TimeInterval] = [15 * 60, 3600, 6 * 3600]

    // When a load is due: now without data (or unreadable), else when the data gets maxAge old;
    // never before notBefore (after a failure, or nothing newer on the server).
    static func loadDue(validFrom: Date?, unreadable: Bool, now: Date, maxAge: TimeInterval, notBefore: Date?) -> Date {
        let due = unreadable || validFrom == nil ? now : validFrom!.addingTimeInterval(maxAge)
        return max(due, notBefore ?? .distantPast)
    }

    // The next look: when the load is due, but within checkInterval, and not sooner than a minute.
    static func nextCheck(due: Date, now: Date) -> Date {
        max(min(due, now.addingTimeInterval(checkInterval)), now.addingTimeInterval(60))
    }

    static func retryDelay(failures: Int) -> TimeInterval {
        retryDelays[min(max(failures, 1), retryDelays.count) - 1]
    }

    // A file is worth loading unless its Last-Modified is no later than the start of the data
    // the modem holds: loading it would put older data in place of newer.
    static func isNewer(lastModified: Date?, than validFrom: Date?) -> Bool {
        guard let lastModified, let validFrom else { return true }
        return lastModified > validFrom
    }

    static func httpDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: s)
    }
}

// The persisted part (state.json "xtra").
struct XTRAState: Equatable {
    var modem: String?                      // the IMEI all this is about
    var lastModified: String?               // of the last file loaded, for If-Modified-Since
    var lastDownload: Date?
    var failures = 0
    var lastError: String?
    var notBefore: Date?

    init() {}

    init(_ j: [String: Any]?) {
        guard let j else { return }
        modem = j["modem"] as? String
        lastModified = j["lastModified"] as? String
        lastDownload = (j["lastDownload"] as? Double).map(Date.init(timeIntervalSince1970:))
        failures = j["failures"] as? Int ?? 0
        lastError = j["lastError"] as? String
        notBefore = (j["notBefore"] as? Double).map(Date.init(timeIntervalSince1970:))
    }

    // Another modem holds other data, and its failures aren't this one's: start over. Nil (not
    // known yet) changes nothing.
    mutating func use(modem imei: String?) {
        guard let imei, imei != modem else { return }
        self = XTRAState()
        modem = imei
    }

    var json: [String: Any] {
        var j: [String: Any] = ["failures": failures]
        j["modem"] = modem
        j["lastModified"] = lastModified
        j["lastDownload"] = lastDownload?.timeIntervalSince1970
        j["lastError"] = lastError
        j["notBefore"] = notBefore?.timeIntervalSince1970
        return j
    }
}

enum XTRADownload {
    static let maxSize = 1 << 20            // the real file is ~60 KB
    // What the RM551E names. For a modem that names none; the RM520N took the same file.
    static let builtInServers = ["https://path1.xtracloud.net/xtra3Mgrbej.bin",
                                 "https://path2.xtracloud.net/xtra3Mgrbej.bin",
                                 "https://path3.xtracloud.net/xtra3Mgrbej.bin"]

    // Config first, then what the modem names, then the built-in list.
    static func servers(configured: [String]?, modem: [String]) -> [String] {
        if let configured, !configured.isEmpty { return configured }
        return modem.isEmpty ? builtInServers : modem
    }

    enum Result: Equatable {
        case file([UInt8], lastModified: String?, from: String)
        case notModified(from: String)
    }

    // The first server that answers, in order. Blocks (up to ~60 s per server); run
    // it off the manager queue. `since`: If-Modified-Since.
    static func fetch(_ servers: [String], since: String?) throws -> Result {
        var errors: [String] = []
        for s in servers {
            guard let url = URL(string: s), url.scheme == "https" else { errors.append("\(s): not https"); continue }
            do {
                return try fetch(url, since: since)
            } catch {
                errors.append("\(url.host ?? s): \(error)")
            }
        }
        throw QMIHostError.failed(errors.isEmpty ? "no XTRA servers" : errors.joined(separator: "; "))
    }

    private static func fetch(_ url: URL, since: String?) throws -> Result {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 60
        cfg.waitsForConnectivity = true         // the modem's own data connection may be coming up
        let receiver = Receiver(url)
        let session = URLSession(configuration: cfg, delegate: receiver, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var req = URLRequest(url: url)
        if let since { req.setValue(since, forHTTPHeaderField: "If-Modified-Since") }
        let task = session.dataTask(with: req)
        task.resume()
        guard let out = receiver.result.wait(timeout: 70) else {
            task.cancel()
            throw QMIHostError.failed("no answer")
        }
        return try out.get()
    }

    // Collects the body, and gives up as soon as it is longer than maxSize (by its
    // Content-Length, or while it arrives). Delegate calls come one at a time.
    private final class Receiver: NSObject, URLSessionDataDelegate {
        let result = BlockingValue<Swift.Result<Result, Error>>()
        private let url: URL
        private var body = Data()
        private var tooLarge = false

        init(_ url: URL) { self.url = url }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            if (response as? HTTPURLResponse)?.statusCode == 200, response.expectedContentLength > Int64(maxSize) {
                tooLarge = true
                completionHandler(.cancel)
                return
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            // Only a 200 body is used; other statuses are reported by their code.
            guard (dataTask.response as? HTTPURLResponse)?.statusCode == 200 else { return }
            body.append(data)
            if body.count > maxSize {
                tooLarge = true
                dataTask.cancel()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let host = url.host ?? url.absoluteString
            if tooLarge { return result.put(.failure(QMIHostError.failed("file larger than \(maxSize) bytes"))) }
            if let error { return result.put(.failure(error)) }
            guard let http = task.response as? HTTPURLResponse else { return result.put(.failure(QMIHostError.failed("not HTTP"))) }
            switch http.statusCode {
            case 304:
                result.put(.success(.notModified(from: host)))
            case 200:
                guard !body.isEmpty else { return result.put(.failure(QMIHostError.failed("empty file"))) }
                result.put(.success(.file([UInt8](body), lastModified: http.value(forHTTPHeaderField: "Last-Modified"), from: host)))
            default:
                result.put(.failure(QMIHostError.failed("HTTP \(http.statusCode)")))
            }
        }
    }
}
