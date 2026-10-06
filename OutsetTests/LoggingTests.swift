//
//  LoggingTests.swift
//  OutsetTests
//

import Testing
import Foundation
import OSLog

@Suite("logFileLevel")
struct LogFileLevelTests {

    @Test("Maps OSLogType onto the log file level vocabulary")
    func mapsLevels() {
        #expect(logFileLevel(.default) == "INFO")
        #expect(logFileLevel(.info) == "INFO")
        #expect(logFileLevel(.debug) == "DEBUG")
        #expect(logFileLevel(.error) == "ERROR")
        #expect(logFileLevel(.fault) == "ERROR")
    }
}

@Suite("formatLogFileLine")
struct FormatLogFileLineTests {

    private var fixedDate: Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 1
        components.hour = 13
        components.minute = 15
        components.second = 14
        return Calendar.current.date(from: components)!
    }

    @Test("Pads the level to five characters after a bracketed local timestamp")
    func formatsInfoLine() {
        let line = formatLogFileLine("Processing boot-every scripts", logLevel: .info, date: fixedDate)
        #expect(line == "[2026-09-01 13:15:14] INFO  Processing boot-every scripts")
    }

    @Test("Five character levels are followed by a single space")
    func formatsErrorLine() {
        let line = formatLogFileLine("Unable to connect to network", logLevel: .fault, date: fixedDate)
        #expect(line == "[2026-09-01 13:15:14] ERROR Unable to connect to network")
    }
}

@Suite("OutsetSession")
struct OutsetSessionTests {

    private func temporaryLogs() -> String {
        let path = NSTemporaryDirectory() + "outset-session-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    @Test("A run writes its files into logs/YYYY-MM-DD/HHMMSS")
    func sessionDirectoryIsSecondResolution() throws {
        let logs = temporaryLogs()
        let start = OutsetSession.formatter("yyyy-MM-dd HH:mm:ss").date(from: "2026-09-03 04:11:07")!
        let session = try #require(OutsetSession(logsDirectory: logs, version: "4.2.0", runType: "login", start: start))

        #expect(session.sessionId == "2026-09-03-041107")
        #expect(session.logFilePath == logs + "/2026-09-03/041107/outset.log")

        session.append(level: "INFO", message: "Processing login-once", date: start)
        session.append(level: "ERROR", message: "script exited 1", date: start)
        session.finish(end: start.addingTimeInterval(12))

        let events = try String(contentsOfFile: session.sessionDir + "/events.jsonl", encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(events.count == 2)
        let second = try #require(try JSONSerialization.jsonObject(with: Data(events[1].utf8)) as? [String: Any])
        #expect(second["level"] as? String == "ERROR")
        #expect(second["status"] as? String == "FAILED")

        let record = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: session.sessionDir + "/session.json"))) as? [String: Any])
        #expect(record["run_type"] as? String == "login")
        #expect(record["status"] as? String == "partial_failure")
        #expect(record["duration_seconds"] as? Int == 12)
        #expect(record["tool_version"] as? String == "4.2.0")
    }

    @Test("A second run in the same second gets a suffix")
    func sameSecondCollision() throws {
        let logs = temporaryLogs()
        let start = OutsetSession.formatter("yyyy-MM-dd HH:mm:ss").date(from: "2026-09-03 04:11:07")!
        _ = try #require(OutsetSession(logsDirectory: logs, version: "v", runType: "boot", start: start))
        let second = try #require(OutsetSession(logsDirectory: logs, version: "v", runType: "boot", start: start))
        #expect(second.sessionId == "2026-09-03-041107_2")
    }

    @Test("A symlink planted under the day's name is not followed or changed")
    func dayDirectorySymlinkIsRefused() throws {
        let logs = temporaryLogs()
        let target = temporaryLogs()
        chmod(target, 0o755)
        try FileManager.default.createSymbolicLink(atPath: logs + "/2026-09-03", withDestinationPath: target)
        let start = OutsetSession.formatter("yyyy-MM-dd HH:mm:ss").date(from: "2026-09-03 04:11:07")!

        // Root sets the entry aside and makes its own day; any other account stays off it.
        let session = OutsetSession(logsDirectory: logs, version: "v", runType: "boot", start: start)
        #expect((session != nil) == (geteuid() == 0))
        var info = stat()
        #expect(stat(target, &info) == 0)
        #expect(info.st_mode & 0o7777 == 0o755)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target).isEmpty)
    }

    @Test("An existing day directory keeps its mode")
    func existingDayDirectoryModeIsLeftAlone() throws {
        let logs = temporaryLogs()
        let day = logs + "/2026-09-03"
        try FileManager.default.createDirectory(atPath: day, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o755])
        let start = OutsetSession.formatter("yyyy-MM-dd HH:mm:ss").date(from: "2026-09-03 04:11:07")!

        _ = try #require(OutsetSession(logsDirectory: logs, version: "v", runType: "boot", start: start))
        var info = stat()
        #expect(lstat(day, &info) == 0)
        #expect(info.st_mode & 0o7777 == 0o755)
    }

    @Test("A set-aside name carries the time it was set aside")
    func untrustedNameRoundTrips() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let name = OutsetSession.untrustedName(day: "2026-09-03", pid: 42, now: now)
        #expect(name == ".untrusted-2026-09-03-42-1790000000")
        #expect(OutsetSession.untrustedDate(name) == now)
        #expect(OutsetSession.untrustedDate("2026-09-03") == nil)
        #expect(OutsetSession.untrustedDate(".untrusted-junk") == nil)
    }

    @Test("Root sets aside a day directory it does not own and makes its own",
          .enabled(if: geteuid() == 0))
    func rootReclaimsForeignDayDirectory() throws {
        let logs = temporaryLogs()
        let day = logs + "/2026-09-03"
        try FileManager.default.createDirectory(atPath: day, withIntermediateDirectories: false)
        chown(day, 4_294_967_294, 4_294_967_294)
        let start = OutsetSession.formatter("yyyy-MM-dd HH:mm:ss").date(from: "2026-09-03 04:11:07")!

        _ = try #require(OutsetSession(logsDirectory: logs, version: "v", runType: "boot", start: start))
        var info = stat()
        #expect(lstat(day, &info) == 0)
        #expect(info.st_uid == 0)
        #expect(info.st_mode & 0o7777 == managedLogDirectoryMode)
        let entries = try FileManager.default.contentsOfDirectory(atPath: logs)
        #expect(entries.filter { $0.hasPrefix(OutsetSession.untrustedPrefix) }.count == 1)
    }

    @Test("Retention removes set-aside entries past the window without following them")
    func retentionRemovesSetAsideEntries() throws {
        let logs = temporaryLogs()
        let target = temporaryLogs()
        let fm = FileManager.default
        fm.createFile(atPath: target + "/keep", contents: Data("x".utf8))
        let now = OutsetSession.formatter("yyyy-MM-dd HH:mm:ss").date(from: "2026-09-03 04:11:07")!
        let old = now.addingTimeInterval(-60 * 24 * 60 * 60)
        let link = logs + "/" + OutsetSession.untrustedName(day: "2026-07-01", pid: 1, now: old)
        let dir = logs + "/" + OutsetSession.untrustedName(day: "2026-07-02", pid: 2, now: old)
        let recent = OutsetSession.untrustedName(day: "2026-09-02", pid: 3, now: now)
        try fm.createSymbolicLink(atPath: link, withDestinationPath: target)
        try fm.createDirectory(atPath: dir + "/120000", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: logs + "/" + recent, withIntermediateDirectories: false)

        #expect(OutsetSession.prune(logsDirectory: logs, now: now) == 2)
        #expect(Set(try fm.contentsOfDirectory(atPath: logs)) == [recent])
        #expect(fm.fileExists(atPath: target + "/keep"))
    }

    @Test("Retention removes day directories past the window and the flat log it replaced")
    func retention() throws {
        let logs = temporaryLogs()
        let now = OutsetSession.formatter("yyyy-MM-dd HH:mm:ss").date(from: "2026-09-03 04:11:07")!
        let fm = FileManager.default
        for day in ["2026-07-01", "2026-08-30"] {
            try fm.createDirectory(atPath: logs + "/" + day + "/120000", withIntermediateDirectories: true)
        }
        for name in ["outset.log", "outset.log.4"] {
            let path = logs + "/" + name
            fm.createFile(atPath: path, contents: Data("x".utf8))
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(-60 * 24 * 60 * 60)], ofItemAtPath: path)
        }

        let removed = OutsetSession.prune(logsDirectory: logs, now: now)

        #expect(removed == 3)
        #expect(Set(try fm.contentsOfDirectory(atPath: logs)) == ["2026-08-30"])
    }
}
