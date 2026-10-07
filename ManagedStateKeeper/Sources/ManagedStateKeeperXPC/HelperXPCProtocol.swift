//
//  HelperXPCProtocol.swift
//  Managed State Keeper
//
//  The protocol, constants and run modes shared by the GUI and the privileged
//  helper. Nothing here touches the outset engine; the helper runs the installed
//  outset binary with the fixed arguments a run mode names.
//

import Foundation

/// Mach service name for the privileged helper.
public let kHelperMachServiceName = "io.macadmins.Outset.helper"

public enum StateKeeperConstants {
    /// The outset preference domain. The helper writes only this domain.
    public static let preferenceDomain = "io.macadmins.Outset"
    /// The signing identifier of the GUI. The helper accepts no other client.
    public static let appIdentifier = "io.macadmins.Outset.gui"
    /// The outset engine, as the outset package installs it.
    public static let outsetExecutablePath = "/usr/local/outset/Outset.app/Contents/MacOS/Outset"
    /// Where root runs of outset write their session directories. Root only.
    public static let logsDirectory = "/Library/Managed State/logs"
    /// Where user-context runs (login-every, login-once, on-demand) write theirs,
    /// relative to the user's home folder.
    public static let userLogsSubpath = "Library/Logs/Managed State"
    /// `userLogsSubpath` in `home`.
    public static func userLogsDirectory(home: String = NSHomeDirectory()) -> String {
        (home as NSString).appendingPathComponent(userLogsSubpath)
    }
    /// The file outset's on-demand LaunchAgent watches in the user's session.
    public static let onDemandTrigger = "/private/tmp/.io.macadmins.outset.ondemand.launchd"
}

/// The outset runs that make sense to start by hand. Each maps to fixed engine
/// arguments; a caller names a mode and never supplies a command line.
public enum RunMode: String, CaseIterable, Identifiable, Sendable {
    case loginPrivileged = "login-privileged"
    case onDemandPrivileged = "on-demand-privileged"
    case onDemand = "on-demand"
    case boot = "boot"

    public var id: String { rawValue }

    /// The engine arguments the helper runs for this mode.
    public var arguments: [String] { ["--\(rawValue)"] }

    /// On-demand runs in the signed-in user's session through outset's own
    /// LaunchAgent, so it is started by its trigger file rather than by the helper.
    public var runsInHelper: Bool { self != .onDemand }

    public var title: String {
        switch self {
        case .loginPrivileged: "Login (privileged)"
        case .onDemandPrivileged: "On-demand (privileged)"
        case .onDemand: "On-demand (user)"
        case .boot: "Boot"
        }
    }

    public var summary: String {
        switch self {
        case .loginPrivileged:
            "Runs login-privileged-once and login-privileged-every as root for the signed-in user."
        case .onDemandPrivileged:
            "Runs the on-demand-privileged items as root, then removes them, as outset always does."
        case .onDemand:
            "Asks outset's LaunchAgent to run the on-demand items as the signed-in user. Its output goes to that run's own log session."
        case .boot:
            "Runs boot-every and any boot-once items still pending, as at start-up."
        }
    }
}

/// The outset preferences the window edits. The helper refuses every other key,
/// so a client cannot use it to rewrite run-once records or the signing key.
public enum OutsetPreferenceKey: String, CaseIterable, Sendable {
    case waitForNetwork = "wait_for_network"
    case networkTimeout = "network_timeout"
    case backgroundScriptTimeout = "background_script_timeout"
    case ignoredUsers = "ignored_users"
    case verboseLogging = "verbose_logging"

    public static func isWritable(_ key: String) -> Bool {
        OutsetPreferenceKey(rawValue: key) != nil
    }

    /// True when the helper may write the key: it is one the window edits and no
    /// configuration profile forces it. A profile-set value always wins, so a write
    /// underneath it would only leave a stale value behind.
    public static func isWritable(_ key: String, isForced: (String) -> Bool) -> Bool {
        isWritable(key) && !isForced(key)
    }

    /// The managed preferences file a configuration profile writes for the domain.
    public static let managedPreferencesPath =
        "/Library/Managed Preferences/\(StateKeeperConstants.preferenceDomain).plist"

    /// True when the managed preferences plist at `path` sets `key`. The helper is
    /// long-lived and CFPreferences keeps the managed layer it loaded at start-up, so
    /// a profile that arrives later is checked for in the file as well.
    public static func managedFileSetsKey(_ key: String, path: String = managedPreferencesPath) -> Bool {
        guard let dict = NSDictionary(contentsOfFile: path) else { return false }
        return dict[key] != nil
    }
}

/// Protocol exposed by the privileged helper daemon. All methods run as root.
/// XPC proxies are thread-safe by design; Sendable conformance is safe.
@objc public protocol HelperXPCProtocol: Sendable {
    /// Run outset in the named mode. Output streams back over the client protocol.
    func run(mode: String)

    /// Stop the run in progress.
    func stop()

    /// Write a preference to /Library/Preferences/io.macadmins.Outset.plist.
    func setBoolPreference(key: String, value: Bool, withReply reply: @escaping (Bool) -> Void)
    func setIntPreference(key: String, value: Int, withReply reply: @escaping (Bool) -> Void)
    func setArrayPreference(key: String, value: [String], withReply reply: @escaping (Bool) -> Void)
    func removePreference(key: String, withReply reply: @escaping (Bool) -> Void)

    /// The helper's version, to confirm it is alive.
    func getHelperVersion(withReply reply: @escaping (String) -> Void)
}

/// Callback protocol from the helper back to the GUI.
@objc public protocol HelperXPCClientProtocol: Sendable {
    /// One line of output from the running outset process.
    func didReceiveOutput(_ line: String)

    /// The outset process finished.
    func runDidComplete(success: Bool, exitCode: Int32)

    /// The helper hit an error outside a normal run.
    func didEncounterError(_ message: String)
}

public extension NSXPCInterface {
    /// The helper interface with the string array argument of
    /// setArrayPreference allowed through secure coding.
    static func stateKeeperHelperInterface() -> NSXPCInterface {
        let interface = NSXPCInterface(with: HelperXPCProtocol.self)
        let classes = NSSet(array: [NSArray.self, NSString.self]) as! Set<AnyHashable>
        interface.setClasses(
            classes,
            for: #selector(HelperXPCProtocol.setArrayPreference(key:value:withReply:)),
            argumentIndex: 1,
            ofReply: false
        )
        return interface
    }
}
