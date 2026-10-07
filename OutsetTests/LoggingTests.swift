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
                                                attributes: [.posixPermissions: 0o750])
        let start = OutsetSession.formatter("yyyy-MM-dd HH:mm:ss").date(from: "2026-09-03 04:11:07")!

        _ = try #require(OutsetSession(logsDirectory: logs, version: "v", runType: "boot", start: start))
        var info = stat()
        #expect(lstat(day, &info) == 0)
        #expect(info.st_mode & 0o7777 == 0o750)
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

    @Test("A link inside an expired day directory is unlinked and its target survives")
    func retentionUnlinksLinksInsideExpiredDays() throws {
        let logs = temporaryLogs()
        let target = temporaryLogs()
        let fm = FileManager.default
        fm.createFile(atPath: target + "/keep", contents: Data("x".utf8))
        try fm.createDirectory(atPath: logs + "/2026-07-01/120000", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: logs + "/2026-07-01/link", withDestinationPath: target)
        try fm.createSymbolicLink(atPath: logs + "/2026-07-01/120000/link", withDestinationPath: target)
        let now = OutsetSession.formatter("yyyy-MM-dd HH:mm:ss").date(from: "2026-09-03 04:11:07")!

        #expect(OutsetSession.prune(logsDirectory: logs, now: now) == 1)
        #expect(try fm.contentsOfDirectory(atPath: logs).isEmpty)
        #expect(fm.fileExists(atPath: target + "/keep"))
    }

    @Test("A folder nested below a session directory is left in place")
    func retentionLeavesDeeperFolders() throws {
        let logs = temporaryLogs()
        let fm = FileManager.default
        try fm.createDirectory(atPath: logs + "/2026-07-01/120000/deeper", withIntermediateDirectories: true)
        fm.createFile(atPath: logs + "/2026-07-01/120000/outset.log", contents: Data("x".utf8))
        let now = OutsetSession.formatter("yyyy-MM-dd HH:mm:ss").date(from: "2026-09-03 04:11:07")!

        #expect(OutsetSession.prune(logsDirectory: logs, now: now) == 0)
        #expect(fm.fileExists(atPath: logs + "/2026-07-01/120000/deeper"))
        #expect(!fm.fileExists(atPath: logs + "/2026-07-01/120000/outset.log"))
    }

    @Test("A link named like a recent day is not walked by the session cap")
    func sessionCapIgnoresLinkedDays() throws {
        let logs = temporaryLogs()
        let target = temporaryLogs()
        let fm = FileManager.default
        for index in 0..<(OutsetSession.maxSessions + 5) {
            try fm.createDirectory(atPath: target + String(format: "/%06d", index), withIntermediateDirectories: false)
        }
        try fm.createSymbolicLink(atPath: logs + "/2026-09-02", withDestinationPath: target)
        let now = OutsetSession.formatter("yyyy-MM-dd HH:mm:ss").date(from: "2026-09-03 04:11:07")!

        #expect(OutsetSession.prune(logsDirectory: logs, now: now) == 0)
        #expect(try fm.contentsOfDirectory(atPath: target).count == OutsetSession.maxSessions + 5)
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

@Suite("Log locations")
struct LogLocationTests {

    @Test("User-context runs log under ~/Library/Logs/Managed State")
    func userDirectoryMirrorsTheManagedLayout() {
        #expect(userLogDirectoryPath(home: "/Users/someone") == "/Users/someone/Library/Logs/Managed State")
    }

    @Test("A user's first run creates its log root and a session inside it")
    func firstUserRunCreatesTheRoot() throws {
        let home = NSTemporaryDirectory() + "outset-home-" + UUID().uuidString
        let logs = userLogDirectoryPath(home: home)
        let start = OutsetSession.formatter("yyyy-MM-dd HH:mm:ss").date(from: "2026-09-03 04:11:07")!
        let session = try #require(OutsetSession(logsDirectory: logs, version: "v", runType: "login", start: start))
        #expect(session.logFilePath == logs + "/2026-09-03/041107/outset.log")
        var info = stat()
        #expect(lstat(logs, &info) == 0)
        #expect(info.st_mode & 0o7777 == 0o755)
        #expect(info.st_uid == geteuid())
    }

    @Test("Only a root run with a locked managed directory logs there")
    func contextDecidesTheRoot() {
        let user = "/Users/someone/Library/Logs/Managed State"
        #expect(resolveLogDirectory(isRoot: true, managedReady: true, userDirectory: user) == managedLogDirectory)
        #expect(resolveLogDirectory(isRoot: true, managedReady: false, userDirectory: user) == user)
        #expect(resolveLogDirectory(isRoot: false, managedReady: true, userDirectory: user) == user)
        #expect(resolveLogDirectory(isRoot: false, managedReady: false, userDirectory: user) == user)
    }

    @Test("Recognises paths inside the managed directory and nothing else")
    func insideManagedDirectory() {
        #expect(isInsideManagedLogDirectory(managedLogDirectory))
        #expect(isInsideManagedLogDirectory(managedLogDirectory + "/2026-09-03/041107"))
        #expect(!isInsideManagedLogDirectory(managedLogDirectory + "-other/x"))
        #expect(!isInsideManagedLogDirectory("/Users/someone/Library/Logs/Managed State/2026-09-03"))
    }

    @Test("The managed folder is root's: 0755 folders and 0644 files")
    func managedModes() {
        #expect(managedLogDirectoryMode == 0o755)
        #expect(managedLogFileMode == 0o644)
    }
}

@Suite("Locking the managed log directory")
struct LogDirectoryLockTests {

    private let me = geteuid()
    private let myGroup = getegid()
    private var trusted: Set<uid_t> { [0, geteuid()] }

    /// A scratch folder reached without any symlink (NSTemporaryDirectory sits under /var).
    private func scratch() -> String {
        // realpath, not resolvingSymlinksInPath, which maps /private/var back to /var.
        let base = realpath(NSTemporaryDirectory(), nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? NSTemporaryDirectory()
        let path = base + "/outset-lock-" + UUID().uuidString
        mkdir(path, 0o755)
        chmod(path, 0o755)
        return path
    }

    private func mode(_ path: String) -> mode_t {
        var info = stat()
        lstat(path, &info)
        return info.st_mode & 0o7777
    }

    @Test("Creates the owned folders 0755 and returns the last one")
    func createsOwnedFolders() {
        let base = scratch()
        let logs = base + "/Managed State/logs"
        let fd = openLockedLogDirectory(logs, ownedComponents: 2, trustedOwners: trusted, owner: me, group: myGroup)
        #expect(fd >= 0)
        if fd >= 0 { close(fd) }
        #expect(mode(base + "/Managed State") == 0o755)
        #expect(mode(logs) == 0o755)
    }

    @Test("Resets a world-writable owned folder to 0755")
    func resetsWorldWritableFolder() {
        let base = scratch()
        let logs = base + "/Managed State/logs"
        mkdir(base + "/Managed State", 0o755)
        mkdir(logs, 0o755)
        chmod(logs, 0o1777)
        let fd = openLockedLogDirectory(logs, ownedComponents: 2, trustedOwners: trusted, owner: me, group: myGroup)
        #expect(fd >= 0)
        if fd >= 0 { close(fd) }
        #expect(mode(logs) == 0o755)
    }

    @Test("Refuses a symlink in place of an owned folder and leaves its target alone")
    func refusesOwnedSymlink() throws {
        let base = scratch()
        let target = scratch()
        chmod(target, 0o700)
        try FileManager.default.createSymbolicLink(atPath: base + "/Managed State", withDestinationPath: target)
        let fd = openLockedLogDirectory(base + "/Managed State/logs", ownedComponents: 2,
                                        trustedOwners: trusted, owner: me, group: myGroup)
        #expect(fd == -1)
        #expect(mode(target) == 0o700)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target).isEmpty)
    }

    @Test("Refuses a symlink anywhere above the folder")
    func refusesAncestorSymlink() {
        // /var is a symlink to /private/var on macOS.
        let viaLink = NSTemporaryDirectory().hasPrefix("/var/") ? NSTemporaryDirectory() : "/var/tmp/"
        let fd = openLockedLogDirectory(viaLink + "outset-lock-\(UUID().uuidString)/logs", ownedComponents: 1,
                                        trustedOwners: trusted, owner: me, group: myGroup)
        #expect(fd == -1)
    }

    @Test("Refuses a folder above that other accounts can write")
    func refusesWritableAncestor() {
        let base = scratch()
        chmod(base, 0o777)
        let fd = openLockedLogDirectory(base + "/Managed State/logs", ownedComponents: 2,
                                        trustedOwners: trusted, owner: me, group: myGroup)
        #expect(fd == -1)
        #expect(!FileManager.default.fileExists(atPath: base + "/Managed State"))
    }

    @Test("Resets a world-writable layout and drops links instead of following them")
    func locksLegacyTree() throws {
        let fm = FileManager.default
        let base = scratch()
        let outside = scratch()
        let logs = base + "/Managed State/logs"
        try fm.createDirectory(atPath: logs + "/2026-09-03/041107", withIntermediateDirectories: true)
        for dir in [logs, logs + "/2026-09-03"] { chmod(dir, 0o1777) }
        fm.createFile(atPath: logs + "/outset.log", contents: Data("old".utf8))
        fm.createFile(atPath: logs + "/2026-09-03/041107/outset.log", contents: Data("x".utf8))
        chmod(logs + "/outset.log", 0o666)
        chmod(logs + "/2026-09-03/041107/outset.log", 0o666)
        fm.createFile(atPath: outside + "/secret", contents: Data("s".utf8))
        chmod(outside + "/secret", 0o600)
        try fm.createSymbolicLink(atPath: logs + "/2026-09-03/link", withDestinationPath: outside + "/secret")
        #expect(link(outside + "/secret", logs + "/2026-09-03/041107/events.jsonl") == 0)

        #expect(prepareManagedLogDirectory(logs, ownedComponents: 2, trustedOwners: trusted, owner: me, group: myGroup))

        #expect(mode(logs) == 0o755)
        #expect(mode(logs + "/2026-09-03") == 0o755)
        #expect(mode(logs + "/2026-09-03/041107") == 0o755)
        #expect(mode(logs + "/outset.log") == 0o644)
        #expect(mode(logs + "/2026-09-03/041107/outset.log") == 0o644)
        #expect(!fm.fileExists(atPath: logs + "/2026-09-03/041107/events.jsonl"))
        var info = stat()
        #expect(lstat(logs + "/2026-09-03/link", &info) != 0)
        #expect(mode(outside + "/secret") == 0o600)
        #expect(try String(contentsOfFile: outside + "/secret", encoding: .utf8) == "s")
    }

    @Test("Root locks the tree to root:wheel", .enabled(if: geteuid() == 0))
    func rootOwnsTheTree() throws {
        let base = scratch()
        let logs = base + "/Managed State/logs"
        try FileManager.default.createDirectory(atPath: logs + "/2026-09-03", withIntermediateDirectories: true)
        chown(logs + "/2026-09-03", 4_294_967_294, 4_294_967_294)
        #expect(prepareManagedLogDirectory(logs, ownedComponents: 2, trustedOwners: [0, geteuid()]))
        var info = stat()
        #expect(lstat(logs + "/2026-09-03", &info) == 0)
        #expect(info.st_uid == 0 && info.st_gid == 0)
    }
}
