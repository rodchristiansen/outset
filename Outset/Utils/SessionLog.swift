//
//  SessionLog.swift
//  Outset
//
//  The structured half of a run's logs.
//
//  Every invocation owns a session directory under the log root,
//      /Library/Managed State/logs/YYYY-MM-DD/HHMMSS/
//  holding outset.log (the human log), events.jsonl (one JSON record per line,
//  appended as the run proceeds) and session.json (the run as a whole, written
//  when it starts and rewritten when it ends). The layout and field names match
//  StartSet's session logger on Windows and the managed-software tools on both
//  platforms, so the same readers work everywhere.
//
//  The log root is shared between root and user contexts, so a day directory is
//  created world-writable and sticky the way the root itself is; each context
//  then owns the session directories it creates inside it.
//

import Foundation

/// The run in progress, when it has a session directory. Nil means this
/// invocation writes the flat `outset.log` at the log root, as builds before
/// this layout did.
var currentSession: OutsetSession?

/// One line of events.jsonl.
private struct SessionEvent: Codable {
    var eventId: String
    var sessionId: String
    var timestamp: String
    var level: String
    var eventType: String
    var status: String?
    var message: String
    var error: String?

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case sessionId = "session_id"
        case timestamp
        case level
        case eventType = "event_type"
        case status
        case message
        case error
    }
}

/// Counts for the run, written into session.json.
private struct SessionSummary: Codable {
    var events = 0
    var errors = 0
    var warnings = 0
}

/// The record written to session.json.
private struct SessionRecord: Codable {
    var sessionId: String
    var startTime: String
    var endTime: String?
    var durationSeconds: Int?
    var runType: String
    var status: String
    var toolVersion: String
    var environment: [String: String]
    var summary: SessionSummary

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case startTime = "start_time"
        case endTime = "end_time"
        case durationSeconds = "duration_seconds"
        case runType = "run_type"
        case status
        case toolVersion = "tool_version"
        case environment
        case summary
    }
}

/// Owns one run's session directory and the two machine-readable files in it.
final class OutsetSession {
    /// Day directories older than this are removed when a run starts.
    static let retentionDays = 30
    /// Session directories kept across all days, newest first.
    static let maxSessions = 100

    let sessionId: String
    let sessionDir: String
    let logFilePath: String

    private let startTime: Date
    private let runType: String
    private let version: String
    private let eventsPath: String
    private var summary = SessionSummary()
    private var eventIndex = 0

    /// Creates `logs/YYYY-MM-DD/HHMMSS/`, appending `_2` through `_9` when a
    /// previous run started in the same second. Returns nil when the directory
    /// cannot be created, which leaves the run on the flat log at the root.
    init?(logsDirectory: String, version: String, runType: String, start: Date = Date()) {
        let day = OutsetSession.formatter("yyyy-MM-dd").string(from: start)
        let time = OutsetSession.formatter("HHmmss").string(from: start)
        let dayDir = (logsDirectory as NSString).appendingPathComponent(day)
        guard OutsetSession.makeSharedDirectory(dayDir) else { return nil }

        let fm = FileManager.default
        var chosenDir = (dayDir as NSString).appendingPathComponent(time)
        var chosenName = time
        if fm.fileExists(atPath: chosenDir) {
            var placed = false
            for suffix in 2...9 {
                let candidate = (dayDir as NSString).appendingPathComponent("\(time)_\(suffix)")
                if !fm.fileExists(atPath: candidate) {
                    chosenDir = candidate
                    chosenName = "\(time)_\(suffix)"
                    placed = true
                    break
                }
            }
            if !placed { return nil }
        }
        guard (try? fm.createDirectory(atPath: chosenDir, withIntermediateDirectories: false,
                                       attributes: [FileAttributeKey.posixPermissions: 0o755])) != nil else { return nil }

        self.sessionDir = chosenDir
        self.sessionId = "\(day)-\(chosenName)"
        self.logFilePath = (chosenDir as NSString).appendingPathComponent(logFileName)
        self.eventsPath = (chosenDir as NSString).appendingPathComponent("events.jsonl")
        self.startTime = start
        self.runType = runType
        self.version = version

        writeSessionFile(status: "running")
    }

    /// Appends one record to events.jsonl and keeps the run's counts.
    func append(level: String, message: String, date: Date = Date()) {
        switch level {
        case "ERROR": summary.errors += 1
        case "WARN": summary.warnings += 1
        default: break
        }
        summary.events += 1
        eventIndex += 1

        let event = SessionEvent(
            eventId: "\(sessionId)-\(String(format: "%05d", eventIndex))",
            sessionId: sessionId,
            timestamp: OutsetSession.isoFormatter.string(from: date),
            level: level,
            eventType: level == "ERROR" ? "error" : "message",
            status: level == "ERROR" ? "FAILED" : nil,
            message: message,
            error: level == "ERROR" ? message : nil
        )
        guard let data = try? OutsetSession.eventEncoder.encode(event),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        _ = appendToLogFile(Data(line.utf8), at: eventsPath)
    }

    /// Rewrites session.json with the run's outcome.
    func finish(status: String? = nil, end: Date = Date()) {
        let resolved = status ?? (summary.errors > 0 ? "partial_failure" : "completed")
        writeSessionFile(status: resolved, end: end)
    }

    private func writeSessionFile(status: String, end: Date? = nil) {
        let record = SessionRecord(
            sessionId: sessionId,
            startTime: OutsetSession.isoFormatter.string(from: startTime),
            endTime: end.map { OutsetSession.isoFormatter.string(from: $0) },
            durationSeconds: end.map { Int($0.timeIntervalSince(startTime).rounded()) },
            runType: runType,
            status: status,
            toolVersion: version,
            environment: OutsetSession.environment(),
            summary: summary
        )
        guard let data = try? OutsetSession.sessionEncoder.encode(record) else { return }
        let path = (sessionDir as NSString).appendingPathComponent("session.json")
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    // MARK: - Retention

    /// Removes day directories older than the retention window, then the oldest
    /// session directories beyond the cap, then the flat log and its rotated
    /// generations left at the root by the layout this replaced. Every removal
    /// is best-effort: in the shared sticky directory another context's files
    /// are not this process's to delete.
    @discardableResult
    static func prune(logsDirectory: String, now: Date = Date()) -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: logsDirectory) else { return 0 }
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: now) else { return 0 }
        let dayFormatter = formatter("yyyy-MM-dd")
        var removed = 0

        var surviving: [String] = []
        for entry in entries.sorted(by: >) {
            guard let day = dayFormatter.date(from: entry), isDirectory(entry, in: logsDirectory) else { continue }
            let path = (logsDirectory as NSString).appendingPathComponent(entry)
            if day < cutoff {
                if (try? fm.removeItem(atPath: path)) != nil { removed += 1 }
            } else {
                surviving.append(path)
            }
        }

        var sessions: [String] = []
        for dayPath in surviving {
            guard let names = try? fm.contentsOfDirectory(atPath: dayPath) else { continue }
            for name in names.sorted(by: >) {
                let full = (dayPath as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue { sessions.append(full) }
            }
        }
        if sessions.count > maxSessions {
            for path in sessions[maxSessions...] where (try? fm.removeItem(atPath: path)) != nil { removed += 1 }
        }

        for entry in entries where entry.hasPrefix(logFileName) {
            let path = (logsDirectory as NSString).appendingPathComponent(entry)
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  (attrs[.type] as? FileAttributeType) == .typeRegular,
                  let modified = attrs[.modificationDate] as? Date, modified < cutoff else { continue }
            if (try? fm.removeItem(atPath: path)) != nil { removed += 1 }
        }
        return removed
    }

    // MARK: - Helpers

    /// Creates a day directory inside the shared log root world-writable and
    /// sticky, the way the root itself is, so a run in either context can place
    /// its own session directory in it. Returns true when the directory exists
    /// and this process may create entries in it.
    static func makeSharedDirectory(_ path: String) -> Bool {
        var info = stat()
        if stat(path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR else { return false }
            if (info.st_mode & 0o7777) != managedLogDirectoryMode, info.st_uid == geteuid() {
                chmod(path, managedLogDirectoryMode)
            }
            return access(path, W_OK | X_OK) == 0
        }
        guard mkdir(path, managedLogDirectoryMode) == 0 else { return false }
        chmod(path, managedLogDirectoryMode)
        return access(path, W_OK | X_OK) == 0
    }

    static func isDirectory(_ name: String, in parent: String) -> Bool {
        var isDir: ObjCBool = false
        let full = (parent as NSString).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: full, isDirectory: &isDir) && isDir.boolValue
    }

    static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = format
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }

    static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let eventEncoder = JSONEncoder()

    static let sessionEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted]
        return e
    }()

    static func environment() -> [String: String] {
        let info = ProcessInfo.processInfo
        return [
            "hostname": Host.current().localizedName ?? "Unknown",
            "os_version": info.operatingSystemVersionString,
            "user": NSUserName(),
            "pid": String(info.processIdentifier),
            "command_line": CommandLine.arguments.joined(separator: " ")
        ]
    }
}

/// Ends the run's session. Registered with `atexit` so a run that leaves through
/// `exit()` still closes its session.json rather than leaving it `running`.
func finishOutsetSession() {
    currentSession?.finish()
    currentSession = nil
}
