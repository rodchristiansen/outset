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
