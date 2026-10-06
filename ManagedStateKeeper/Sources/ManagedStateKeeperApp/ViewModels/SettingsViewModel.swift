//
//  SettingsViewModel.swift
//  Managed State Keeper
//
//  outset's preferences for the Prefs tab. Values are read the way the root
//  engine reads them; managed keys are shown locked and never written. Edits
//  auto-save through the privileged helper.
//

import Foundation
import ManagedStateKeeperXPC

/// The editable preferences, as the window holds them.
struct PreferenceSnapshot: Equatable {
    var waitForNetwork = false
    var networkTimeout = 180
    /// Seconds; 0 means background scripts run with no limit.
    var backgroundScriptTimeout = 0
    var ignoredUsers: [String] = []
    var verboseLogging = false
}

/// One write the helper performs.
enum PreferenceWrite: Equatable {
    case bool(OutsetPreferenceKey, Bool)
    case int(OutsetPreferenceKey, Int)
    case array(OutsetPreferenceKey, [String])
    case remove(OutsetPreferenceKey)
}

@Observable
@MainActor
final class SettingsViewModel {

    // MARK: - Values

    var waitForNetwork = false { didSet { scheduleAutoSave() } }
    var networkTimeout = 180 { didSet { scheduleAutoSave() } }
    var backgroundScriptTimeout = 0 { didSet { scheduleAutoSave() } }
    var ignoredUsersText = "" { didSet { scheduleAutoSave() } }
    var verboseLogging = false { didSet { scheduleAutoSave() } }

    /// What outset does with the script-signing key.
    enum SigningKeyState: Equatable {
        case notSet
        case managed
        /// Set outside a profile; outset ignores it.
        case ignored
    }
    private(set) var signingKeyState: SigningKeyState = .notSet

    private(set) var managedKeys: Set<String> = []

    // MARK: - Save Status

    enum SaveStatus: Equatable {
        case idle, saving, saved, failed(String)
    }
    private(set) var saveStatus: SaveStatus = .idle

    // MARK: - Auto-Save

    private let source: PreferenceSource
    private var xpcClient: XPCClient?
    private var autoSaveTask: Task<Void, Never>?
    private var isLoading = false
    private var saved = PreferenceSnapshot()

    init(source: PreferenceSource = SystemPreferenceSource()) {
        self.source = source
    }

    func configure(client: XPCClient) {
        xpcClient = client
    }

    private func scheduleAutoSave() {
        guard !isLoading, xpcClient != nil else { return }
        autoSaveTask?.cancel()
        autoSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.75))
            guard !Task.isCancelled, let self else { return }
            await self.save()
        }
    }

    func isManaged(_ key: OutsetPreferenceKey) -> Bool {
        managedKeys.contains(key.rawValue)
    }

    // MARK: - Load

    func load() {
        isLoading = true
        defer { isLoading = false }

        managedKeys = Set(OutsetPreferenceKey.allCases.map(\.rawValue).filter(source.isManaged))
        let snapshot = Self.read(from: source)
        apply(snapshot)
        saved = snapshot

        let signingKey = "manifest_signing_key"
        if source.isManaged(signingKey) {
            signingKeyState = .managed
        } else if source.value(forKey: signingKey) != nil {
            signingKeyState = .ignored
        } else {
            signingKeyState = .notSet
        }
    }

    /// Reads each value with the meaning the root engine gives it.
    static func read(from source: PreferenceSource) -> PreferenceSnapshot {
        var snapshot = PreferenceSnapshot()
        let waitKey = OutsetPreferenceKey.waitForNetwork.rawValue
        if source.isManaged(waitKey) {
            snapshot.waitForNetwork = boolValue(source.value(forKey: waitKey))
        } else {
            // The root engine treats the key's presence as on, whatever its value.
            snapshot.waitForNetwork = source.value(forKey: waitKey) != nil
        }
        snapshot.networkTimeout = intValue(source.value(forKey: OutsetPreferenceKey.networkTimeout.rawValue)) ?? 180
        snapshot.backgroundScriptTimeout = intValue(source.value(forKey: OutsetPreferenceKey.backgroundScriptTimeout.rawValue)) ?? 0
        snapshot.ignoredUsers = source.value(forKey: OutsetPreferenceKey.ignoredUsers.rawValue) as? [String] ?? []
        snapshot.verboseLogging = boolValue(source.value(forKey: OutsetPreferenceKey.verboseLogging.rawValue))
        return snapshot
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String { return ["1", "true", "yes"].contains(string.lowercased()) }
        return false
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private func apply(_ snapshot: PreferenceSnapshot) {
        waitForNetwork = snapshot.waitForNetwork
        networkTimeout = snapshot.networkTimeout
        backgroundScriptTimeout = snapshot.backgroundScriptTimeout
        ignoredUsersText = snapshot.ignoredUsers.joined(separator: ", ")
        verboseLogging = snapshot.verboseLogging
    }

    private var current: PreferenceSnapshot {
        PreferenceSnapshot(
            waitForNetwork: waitForNetwork,
            networkTimeout: networkTimeout,
            backgroundScriptTimeout: backgroundScriptTimeout,
            ignoredUsers: Self.parseUsers(ignoredUsersText),
            verboseLogging: verboseLogging
        )
    }

    /// Splits the ignored-users field on commas and whitespace, keeping the
    /// first occurrence of each name.
    static func parseUsers(_ text: String) -> [String] {
        var seen = Set<String>()
        return text
            .components(separatedBy: CharacterSet(charactersIn: ",").union(.whitespacesAndNewlines))
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    // MARK: - Save

    /// The writes that take the stored preferences from `old` to `new`,
    /// skipping managed keys. Off and empty values remove the key, which is how
    /// the engine reads "not set".
    static func writes(from old: PreferenceSnapshot, to new: PreferenceSnapshot, managed: Set<String>) -> [PreferenceWrite] {
        var writes: [PreferenceWrite] = []
        func allowed(_ key: OutsetPreferenceKey) -> Bool { !managed.contains(key.rawValue) }

        if old.waitForNetwork != new.waitForNetwork, allowed(.waitForNetwork) {
            writes.append(new.waitForNetwork ? .bool(.waitForNetwork, true) : .remove(.waitForNetwork))
        }
        if old.networkTimeout != new.networkTimeout, allowed(.networkTimeout) {
            writes.append(.int(.networkTimeout, new.networkTimeout))
        }
        if old.backgroundScriptTimeout != new.backgroundScriptTimeout, allowed(.backgroundScriptTimeout) {
            writes.append(new.backgroundScriptTimeout > 0
                ? .int(.backgroundScriptTimeout, new.backgroundScriptTimeout)
                : .remove(.backgroundScriptTimeout))
        }
        if old.ignoredUsers != new.ignoredUsers, allowed(.ignoredUsers) {
            writes.append(new.ignoredUsers.isEmpty ? .remove(.ignoredUsers) : .array(.ignoredUsers, new.ignoredUsers))
        }
        if old.verboseLogging != new.verboseLogging, allowed(.verboseLogging) {
            writes.append(new.verboseLogging ? .bool(.verboseLogging, true) : .remove(.verboseLogging))
        }
        return writes
    }

    func save() async {
        guard let client = xpcClient else { return }
        let target = current
        let pending = Self.writes(from: saved, to: target, managed: managedKeys)
        guard !pending.isEmpty else { return }

        saveStatus = .saving
        var failed: [String] = []
        for write in pending {
            let ok: Bool
            let key: OutsetPreferenceKey
            switch write {
            case .bool(let k, let value): key = k; ok = await client.setBoolPreference(key: k, value: value)
            case .int(let k, let value): key = k; ok = await client.setIntPreference(key: k, value: value)
            case .array(let k, let value): key = k; ok = await client.setArrayPreference(key: k, value: value)
            case .remove(let k): key = k; ok = await client.removePreference(key: k)
            }
            if !ok { failed.append(key.rawValue) }
        }

        if failed.isEmpty {
            saved = target
            saveStatus = .saved
            try? await Task.sleep(for: .seconds(2.5))
            if saveStatus == .saved { saveStatus = .idle }
        } else {
            saveStatus = .failed("Could not save \(failed.joined(separator: ", ")): the helper is not available")
        }
    }
}
