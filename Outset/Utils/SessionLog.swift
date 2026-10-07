//
//  SessionLog.swift
//  Outset
//
//  The structured half of a run's logs.
//
//  Every invocation owns a session directory under its log root,
//      /Library/Managed State/logs/YYYY-MM-DD/HHMMSS/          (root runs)
//      ~/Library/Logs/Managed State/YYYY-MM-DD/HHMMSS/         (user-context runs)
//  holding outset.log (the human log), events.jsonl (one JSON record per line,
//  appended as the run proceeds) and session.json (the run as a whole, written
//  when it starts and rewritten when it ends). The layout and field names match
//  StartSet's session logger on Windows and the managed-software tools on both
//  platforms, so the same readers work everywhere.
//
//  Each log root belongs to one account: root's is root:wheel 0755 and a user's
//  is that user's, so day and session directories are created 0755 and files
//  0644, and nothing in either root is writable by another account.
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
        // A user's log root is created on its first run; the managed one is root's
        // to create, and prepareManagedLogDirectory has already done so.
        if !isInsideManagedLogDirectory(logsDirectory), !checkDirectoryExists(path: logsDirectory) {
            try? FileManager.default.createDirectory(atPath: logsDirectory, withIntermediateDirectories: true,
                                                     attributes: [FileAttributeKey.posixPermissions: 0o755])
        }
        guard OutsetSession.makeDayDirectory(dayDir) else { return nil }

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
        guard (try? data.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil else { return }
        chmod(path, managedLogFileMode)
    }

    // MARK: - Retention

    /// Removes day directories older than the retention window, then the oldest
    /// session directories beyond the cap, then entries root set aside, then
    /// the flat log and its rotated generations left at the root by the layout
    /// this replaced. Every removal is best-effort.
    ///
    /// Nothing here deletes recursively or follows a link. Every step works
    /// relative to a directory opened with O_NOFOLLOW, so an entry swapped for
    /// a link mid-walk is unlinked, never walked into.
    @discardableResult
    static func prune(logsDirectory: String, now: Date = Date()) -> Int {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: now) else { return 0 }
        let root = open(logsDirectory, O_RDONLY | O_DIRECTORY)
        guard root >= 0 else { return 0 }
        defer { close(root) }
        let entries = directoryEntryNames(root)
        let dayFormatter = formatter("yyyy-MM-dd")
        var removed = 0

        var surviving: [String] = []
        for entry in entries.sorted(by: >) {
            guard let day = dayFormatter.date(from: entry), isDirectoryEntry(entry, in: root) else { continue }
            if day < cutoff {
                if removeEntryNoFollow(entry, in: root, depth: 1) { removed += 1 }
            } else {
                surviving.append(entry)
            }
        }

        var dayDescriptors: [Int32] = []
        defer { dayDescriptors.forEach { close($0) } }
        var sessions: [(day: Int32, name: String)] = []
        for day in surviving {
            let fd = openat(root, day, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard fd >= 0 else { continue }
            dayDescriptors.append(fd)
            for name in directoryEntryNames(fd).sorted(by: >) where isDirectoryEntry(name, in: fd) {
                sessions.append((fd, name))
            }
        }
        if sessions.count > maxSessions {
            for session in sessions[maxSessions...] where removeEntryNoFollow(session.name, in: session.day) {
                removed += 1
            }
        }

        for entry in entries {
            guard let setAsideAt = untrustedDate(entry), setAsideAt < cutoff else { continue }
            if removeEntryNoFollow(entry, in: root, depth: 1) { removed += 1 }
        }

        for entry in entries where entry.hasPrefix(logFileName) {
            var info = stat()
            guard fstatat(root, entry, &info, AT_SYMLINK_NOFOLLOW) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  Double(info.st_mtimespec.tv_sec) < cutoff.timeIntervalSince1970 else { continue }
            if unlinkat(root, entry, 0) == 0 { removed += 1 }
        }
        return removed
    }

    // MARK: - Helpers

    /// Creates a day directory, mode 0755, inside the log root. Returns true
    /// when the directory exists, is trusted, and this process may create
    /// entries in it.
    ///
    /// An existing entry is read with lstat and never followed, and its mode is
    /// never changed: only a directory this process just created gets chmod. An
    /// existing directory is trusted only when owned by root or by this process.
    /// A root run that finds anything else under the day's name renames it aside
    /// and creates its own, so root records stay in the collected location.
    static func makeDayDirectory(_ path: String) -> Bool {
        var info = stat()
        if lstat(path, &info) == 0 {
            let trusted = (info.st_mode & S_IFMT) == S_IFDIR && (info.st_uid == 0 || info.st_uid == geteuid())
            if trusted { return access(path, W_OK | X_OK) == 0 }
            guard geteuid() == 0, setAside(path) else { return false }
        }
        guard mkdir(path, managedLogDirectoryMode) == 0 else { return false }
        chmod(path, managedLogDirectoryMode)
        return access(path, W_OK | X_OK) == 0
    }

    /// Renames `path` to a hidden name beside it. rename never follows a link,
    /// and root may rename any entry in a root-owned parent. Only done when the
    /// parent is a real directory owned by root.
    static func setAside(_ path: String, now: Date = Date()) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        var info = stat()
        guard lstat(parent, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == 0 else { return false }
        let name = untrustedName(day: (path as NSString).lastPathComponent, pid: getpid(), now: now)
        return rename(path, (parent as NSString).appendingPathComponent(name)) == 0
    }

    static let untrustedPrefix = ".untrusted-"

    /// The hidden name an entry set aside by `setAside` gets.
    static func untrustedName(day: String, pid: Int32, now: Date) -> String {
        return "\(untrustedPrefix)\(day)-\(pid)-\(Int(now.timeIntervalSince1970))"
    }

    /// When an entry named by `untrustedName` was set aside, or nil for any other name.
    static func untrustedDate(_ name: String) -> Date? {
        guard name.hasPrefix(untrustedPrefix), let last = name.split(separator: "-").last,
              let epoch = Int(last) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(epoch))
    }

    /// Names in the directory open at `fd`, without "." and "..".
    static func directoryEntryNames(_ fd: Int32) -> [String] {
        let copy = dup(fd)
        guard copy >= 0 else { return [] }
        guard let dir = fdopendir(copy) else { close(copy); return [] }
        defer { closedir(dir) }
        rewinddir(dir)
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                String(cString: bytes.bindMemory(to: CChar.self).baseAddress!)
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    /// True when `name` in the directory open at `fd` is a real directory, not a link.
    static func isDirectoryEntry(_ name: String, in fd: Int32) -> Bool {
        var info = stat()
        return fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// Removes `name` from the directory open at `parent` without following a
    /// link. A link or file is unlinked. A directory is opened with O_NOFOLLOW,
    /// its files and links unlinked, its subdirectories handled the same way
    /// down to `depth` more levels, and it is removed only once it is empty;
    /// anything deeper is left in place. Returns true when the entry is gone.
    @discardableResult
    static func removeEntryNoFollow(_ name: String, in parent: Int32, depth: Int = 0) -> Bool {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return unlinkat(parent, name, 0) == 0 }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        for child in directoryEntryNames(fd) {
            if isDirectoryEntry(child, in: fd) {
                if depth > 0 { removeEntryNoFollow(child, in: fd, depth: depth - 1) }
            } else {
                unlinkat(fd, child, 0)
            }
        }
        close(fd)
        return unlinkat(parent, name, AT_REMOVEDIR) == 0
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
