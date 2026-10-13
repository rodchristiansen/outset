//
//  SettingsViewModel.swift
//  Managed State Keeper
//
//  outset's preferences for the Prefs tab. Values are read the way the root
//  engine reads them; managed keys are shown gray and never written. Other
//  edits are held until the user saves; Save asks for an administrator and
//  writes through the privileged helper, which checks that authorization.
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

    var key: OutsetPreferenceKey {
        switch self {
        case .bool(let key, _), .int(let key, _), .array(let key, _), .remove(let key): key
        }
    }
}

/// Performs one write with an administrator's authorization.
@MainActor
protocol PreferenceWriting: AnyObject {
    func perform(_ write: PreferenceWrite, authorization: Data) async -> Bool
}

extension XPCClient: PreferenceWriting {
    func perform(_ write: PreferenceWrite, authorization: Data) async -> Bool {
        switch write {
        case .bool(let key, let value): await setBoolPreference(key: key, value: value, authorization: authorization)
        case .int(let key, let value): await setIntPreference(key: key, value: value, authorization: authorization)
        case .array(let key, let value): await setArrayPreference(key: key, value: value, authorization: authorization)
        case .remove(let key): await removePreference(key: key, authorization: authorization)
        }
    }
}

@Observable
@MainActor
final class SettingsViewModel {

    // MARK: - Values

    var waitForNetwork = false
    var networkTimeout = 180
    var backgroundScriptTimeout = 0
    var ignoredUsersText = ""
    var verboseLogging = false

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

    // MARK: - Save

    private let source: PreferenceSource
    private let authorizer: AdminAuthorizing
    private var writer: PreferenceWriting?
    private var saved = PreferenceSnapshot()

    init(source: PreferenceSource = SystemPreferenceSource(), authorizer: AdminAuthorizing = AdminAuthorization()) {
        self.source = source
        self.authorizer = authorizer
    }

    func configure(client: PreferenceWriting) {
        writer = client
    }

    /// True when an edit to a key no profile manages has not been saved.
    var hasUnsavedChanges: Bool {
        !Self.writes(from: saved, to: current, managed: managedKeys).isEmpty
    }

    /// True when a profile manages every key the window edits, so there is
    /// nothing to save and the window is read-only.
    var isFullyManaged: Bool {
        OutsetPreferenceKey.allCases.allSatisfy { managedKeys.contains($0.rawValue) }
    }

    /// Discards unsaved edits.
    func revert() {
        apply(saved)
        if case .failed = saveStatus { saveStatus = .idle }
    }

    /// True when a profile forces at least one of outset's keys, the signing
    /// key included.
    var hasManagedSettings: Bool {
        if case .managed = signingKeyState { return true }
        return !managedKeys.isEmpty
    }

    func isManaged(_ key: OutsetPreferenceKey) -> Bool {
        managedKeys.contains(key.rawValue)
    }

    // MARK: - Load

    func load() {
        managedKeys = Set(OutsetPreferenceKey.allCases.map(\.rawValue).filter(source.isManaged))
        let snapshot = Self.read(from: source)
        apply(snapshot)
        saved = snapshot

        let signingKey = "manifest_signing_key"
        if source.isManaged(signingKey) {
            signingKeyState = .managed
        } else if let key = source.value(forKey: signingKey) as? String,
                  !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // An empty key left behind by an older outset is no key at all.
            signingKeyState = .ignored
        } else {
            signingKeyState = .notSet
        }
    }

    /// Reads each value with the meaning the root engine gives it.
    static func read(from source: PreferenceSource) -> PreferenceSnapshot {
        var snapshot = PreferenceSnapshot()
        let waitKey = OutsetPreferenceKey.waitForNetwork.rawValue
        // Read by value, as the engine does from #6 on; an older engine treated
        // any stored value, even false, as on.
        snapshot.waitForNetwork = boolValue(source.value(forKey: waitKey))
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

    /// Asks for an administrator once, then writes every pending change with
    /// that authorization and destroys it. Cancelling the prompt keeps the
    /// edits in place, unsaved.
    func save() async {
        guard let writer, saveStatus != .saving else { return }
        let target = current
        let pending = Self.writes(from: saved, to: target, managed: managedKeys)
        guard !pending.isEmpty else { return }

        guard let authorization = authorizer.authorize() else { return }
        defer { authorizer.release() }

        saveStatus = .saving
        var failed: [String] = []
        for write in pending where !(await writer.perform(write, authorization: authorization)) {
            failed.append(write.key.rawValue)
        }

        if failed.isEmpty {
            saved = target
            saveStatus = .saved
            try? await Task.sleep(for: .seconds(2.5))
            if saveStatus == .saved { saveStatus = .idle }
        } else {
            saveStatus = .failed("Could not save \(failed.joined(separator: ", ")): the helper refused or is not available")
        }
    }
}
