import Foundation

// Running a system command (ifconfig, route) and reading what it printed.
enum Shell {
    // stdout and stderr together. Throws when it exits non-zero, with its output. The output is
    // read to the end before waiting: a command filling the pipe would never exit otherwise.
    @discardableResult
    static func run(_ path: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw QMIHostError.failed("\(path) \(args.joined(separator: " ")): \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return out
    }
}
