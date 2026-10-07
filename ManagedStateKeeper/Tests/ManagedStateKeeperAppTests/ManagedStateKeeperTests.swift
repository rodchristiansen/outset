import Foundation
import Testing
@testable import ManagedStateKeeperApp
import ManagedStateKeeperXPC

// MARK: - Line levels, against the lines outset actually writes

@Suite struct LineLevelTests {
    @Test func logFileLevels() {
        #expect(LineLevel.classify("[2026-10-06 09:14:02] ERROR Script failed: /usr/local/outset/boot-every/a.sh") == .error)
        #expect(LineLevel.classify("[2026-10-06 09:14:02] WARN  Network timeout reached") == .warning)
        #expect(LineLevel.classify("[2026-10-06 09:14:02] DEBUG Loading preference file") == .debug)
        #expect(LineLevel.classify("[2026-10-06 09:14:02] INFO  Processing on-demand") == .info)
        #expect(LineLevel.classify("[2026-10-06 09:14:02] INFO  === Boot ===") == .header)
    }

    @Test func consoleLevels() {
        #expect(LineLevel.classify("ERROR: Unable to write log file at /tmp/x") == .error)
        #expect(LineLevel.classify("FAULT: something broke") == .error)
        #expect(LineLevel.classify("DEBUG: Storing preference file") == .debug)
        #expect(LineLevel.classify("INFO: Processing scheduled runs for boot") == .info)
        #expect(LineLevel.classify("DEFAULT: plain line") == .info)
        #expect(LineLevel.classify("WARN: Run stopped by user.") == .warning)
    }

    @Test func markersAndPlainText() {
        #expect(LineLevel.classify("[X] failed") == .error)
        #expect(LineLevel.classify("[!] careful") == .warning)
        #expect(LineLevel.classify("[+] done") == .success)
        #expect(LineLevel.classify("a script's own output: with a colon") == .info)
        #expect(LineLevel.classify("=== section") == .header)
    }
}

// MARK: - Log sessions

@Suite struct LogSessionStoreTests {
    @Test func stampParsing() throws {
        let seconds = try #require(LogSessionStore.parseStamp("2026-10-06-091402"))
        let minutes = try #require(LogSessionStore.parseStamp("2026-10-06-0914"))
        let suffixed = try #require(LogSessionStore.parseStamp("2026-10-06-091402_2"))
        #expect(seconds == suffixed)
        #expect(seconds.timeIntervalSince(minutes) == 2)
        #expect(LogSessionStore.parseStamp("outset") == nil)
    }

    @Test func listsSessionsAndLegacyFilesNewestFirst() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("msk-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: root) }

        func write(_ relative: String, _ text: String = "x") throws {
            let path = (root as NSString).appendingPathComponent(relative)
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        }
        try write("2026-10-05/230000/outset.log")
        try write("2026-10-05/230000/events.jsonl")
        try write("2026-10-06/091402/outset.log", "longer content")
        try write("2026-10-06/091402_2/outset.log")
        try write("2026-10-06/empty/session.json")
        try write("outset.log")
        try write("outset.log.1")
        // Flat logs sort by modification time; date them before every session.
        for name in ["outset.log", "outset.log.1"] {
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)],
                                 ofItemAtPath: (root as NSString).appendingPathComponent(name))
        }

        let sessions = LogSessionStore.sessions(in: root)
        let names = sessions.map(\.name)
        #expect(names.prefix(3) == ["2026-10-06-091402_2", "2026-10-06-091402", "2026-10-05-230000"])
        #expect(names.contains("outset.log"))
        #expect(names.contains("outset.log.1"))
        #expect(!names.contains { $0.contains("empty") })
        #expect(sessions.first { $0.name == "2026-10-06-091402" }?.size == 14)
        #expect(sessions.first?.path.hasSuffix("091402_2/outset.log") == true)
    }

    @Test func missingRootListsNothing() {
        #expect(LogSessionStore.sessions(in: "/nonexistent/\(UUID().uuidString)").isEmpty)
    }
}

// MARK: - Run modes

@Suite struct RunModeTests {
    @Test func fixedArguments() {
        #expect(RunMode.loginPrivileged.arguments == ["--login-privileged"])
        #expect(RunMode.onDemandPrivileged.arguments == ["--on-demand-privileged"])
        #expect(RunMode.boot.arguments == ["--boot"])
    }

    @Test func onlyOnDemandBypassesTheHelper() {
        #expect(RunMode.allCases.filter { !$0.runsInHelper } == [.onDemand])
    }

    @Test func unknownModesAreRejected() {
        #expect(RunMode(rawValue: "checksum") == nil)
        #expect(RunMode(rawValue: "--boot") == nil)
    }

    @Test func helperAcceptsOnlyWindowKeys() {
        #expect(OutsetPreferenceKey.isWritable("network_timeout"))
        #expect(!OutsetPreferenceKey.isWritable("manifest_signing_key"))
        #expect(!OutsetPreferenceKey.isWritable("run_once"))
        #expect(!OutsetPreferenceKey.isWritable("override_login_once"))
    }
}

// MARK: - Preferences

private struct FakeSource: PreferenceSource {
    var values: [String: Any] = [:]
    var managed: Set<String> = []
    func value(forKey key: String) -> Any? { values[key] }
    func isManaged(_ key: String) -> Bool { managed.contains(key) }
}

@Suite @MainActor struct PreferenceTests {
    @Test func readsWithTheEnginesMeaning() {
        let snapshot = SettingsViewModel.read(from: FakeSource(values: [
            "wait_for_network": false,
            "network_timeout": 60,
            "ignored_users": ["admin"],
            "verbose_logging": 1
        ]))
        // A stored false is off, as the engine reads it.
        #expect(!snapshot.waitForNetwork)
        #expect(snapshot.networkTimeout == 60)
        #expect(snapshot.backgroundScriptTimeout == 0)
        #expect(snapshot.ignoredUsers == ["admin"])
        #expect(snapshot.verboseLogging)
    }

    @Test func managedWaitForNetworkUsesItsValue() {
        let snapshot = SettingsViewModel.read(from: FakeSource(
            values: ["wait_for_network": false],
            managed: ["wait_for_network"]
        ))
        #expect(!snapshot.waitForNetwork)
    }

    @Test func defaultsWhenUnset() {
        #expect(SettingsViewModel.read(from: FakeSource()) == PreferenceSnapshot())
    }

    @Test func loadMarksManagedKeys() {
        let model = SettingsViewModel(source: FakeSource(
            values: ["network_timeout": 30, "manifest_signing_key": "abc"],
            managed: ["network_timeout", "manifest_signing_key"]
        ))
        model.load()
        #expect(model.isManaged(.networkTimeout))
        #expect(!model.isManaged(.ignoredUsers))
        #expect(model.networkTimeout == 30)
        #expect(model.signingKeyState == .managed)
    }

    @Test func unmanagedSigningKeyIsReportedIgnored() {
        let model = SettingsViewModel(source: FakeSource(values: ["manifest_signing_key": "abc"]))
        model.load()
        #expect(model.signingKeyState == .ignored)
    }

    @Test func writesSkipManagedKeysAndRemoveOffValues() {
        var new = PreferenceSnapshot()
        new.waitForNetwork = true
        new.networkTimeout = 90
        new.backgroundScriptTimeout = 0
        new.ignoredUsers = ["admin", "support"]
        var old = PreferenceSnapshot()
        old.backgroundScriptTimeout = 600
        old.verboseLogging = true

        let writes = SettingsViewModel.writes(from: old, to: new, managed: ["network_timeout"])
        #expect(writes == [
            .bool(.waitForNetwork, true),
            .remove(.backgroundScriptTimeout),
            .array(.ignoredUsers, ["admin", "support"]),
            .remove(.verboseLogging)
        ])
        #expect(SettingsViewModel.writes(from: new, to: new, managed: []).isEmpty)
    }

    @Test func parsesIgnoredUsers() {
        #expect(SettingsViewModel.parseUsers(" admin, support\nadmin  guest,,") == ["admin", "support", "guest"])
        #expect(SettingsViewModel.parseUsers("").isEmpty)
    }
}
