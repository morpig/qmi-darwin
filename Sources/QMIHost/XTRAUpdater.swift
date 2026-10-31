import Foundation
import QMIKit

// Keeping the modem's XTRA data fresh. The modem has not been seen fetching it by itself
// under qmid, so qmid downloads the file from the servers the modem names and loads it
// (GNSSAssist.load) once the data is older than maxAge, or missing / unreadable. The download
// goes over the Mac's default route. See docs/API.md, "GNSS assistance (XTRA)".

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
    var lastModified: String?               // of the last file loaded, for If-Modified-Since
    var lastDownload: Date?
    var failures = 0
    var lastError: String?
    var notBefore: Date?

    init() {}

    init(_ j: [String: Any]?) {
        guard let j else { return }
        lastModified = j["lastModified"] as? String
        lastDownload = (j["lastDownload"] as? Double).map(Date.init(timeIntervalSince1970:))
        failures = j["failures"] as? Int ?? 0
        lastError = j["lastError"] as? String
        notBefore = (j["notBefore"] as? Double).map(Date.init(timeIntervalSince1970:))
    }

    var json: [String: Any] {
        var j: [String: Any] = ["failures": failures]
        j["lastModified"] = lastModified
        j["lastDownload"] = lastDownload?.timeIntervalSince1970
        j["lastError"] = lastError
        j["notBefore"] = notBefore?.timeIntervalSince1970
        return j
    }
}

enum XTRADownload {
    static let maxSize = 1 << 20            // the real file is ~60 KB

    enum Result {
        case file([UInt8], lastModified: String?, from: String)
        case notModified(from: String)
    }

    // The first server that answers, in the modem's order. Blocks (up to ~60 s per server); run
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
        throw QMIHostError.transport(errors.isEmpty ? "no XTRA servers" : errors.joined(separator: "; "))
    }

    private static func fetch(_ url: URL, since: String?) throws -> Result {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 60
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        var req = URLRequest(url: url)
        if let since { req.setValue(since, forHTTPHeaderField: "If-Modified-Since") }
        let done = DispatchSemaphore(value: 0)
        var out: Swift.Result<Result, Error> = .failure(QMIHostError.transport("no answer"))
        session.dataTask(with: req) { data, response, error in
            defer { done.signal() }
            if let error { out = .failure(error); return }
            guard let http = response as? HTTPURLResponse else { out = .failure(QMIHostError.transport("not HTTP")); return }
            switch http.statusCode {
            case 304:
                out = .success(.notModified(from: url.host ?? url.absoluteString))
            case 200:
                guard let data, !data.isEmpty, data.count <= maxSize else {
                    out = .failure(QMIHostError.transport("file of \(data?.count ?? 0) bytes")); return
                }
                out = .success(.file([UInt8](data), lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
                                     from: url.host ?? url.absoluteString))
            default:
                out = .failure(QMIHostError.transport("HTTP \(http.statusCode)"))
            }
        }.resume()
        _ = done.wait(timeout: .now() + 70)
        return try out.get()
    }
}
