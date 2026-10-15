//
//  Preferences.swift
//  Outset
//
//  Created by Bart E Reardon on 5/9/2023.
//

import Foundation

typealias RunOnce = [String: Date]

struct OutsetPreferences: Codable {
    var waitForNetwork: Bool = defaultWaitForNetwork
    var networkTimeout: Int = defaultNetworkTimeout
    var ignoredUsers: [String] = []
    var overrideLoginOnce: RunOnce = RunOnce()
    // Timeout in seconds for background scripts (default 30). A value of 0
    // disables the limit and background scripts run until they exit naturally.
    var backgroundScriptTimeout: Int = defaultBackgroundScriptTimeout
    // Optional base64-encoded Ed25519 public key. When present (typically delivered
    // via MDM), every script must carry a valid embedded `# ed25519: <sig>` comment.
    // Scripts without a valid signature are refused.
    var manifestSigningKey: String = ""

    enum CodingKeys: String, CodingKey {
        case waitForNetwork = "wait_for_network"
        case networkTimeout = "network_timeout"
        case ignoredUsers = "ignored_users"
        case overrideLoginOnce = "override_login_once"
        case backgroundScriptTimeout = "background_script_timeout"
        case manifestSigningKey = "manifest_signing_key"
    }
}

func writeOutsetPreferences(prefs: OutsetPreferences) {
    if debugMode { showPreferencePath("Stor") }

    let defaults = UserDefaults.standard
    let appID = Bundle.main.bundleIdentifier! as CFString

    let mirror = Mirror(reflecting: prefs)
    for child in mirror.children {
        guard let propertyName = child.label else { continue }
        let key = propertyName.camelCaseToUnderscored()

        if isRoot {
            // A profile owns a managed key; copying it into /Library/Preferences
            // would leave it behind after the profile is removed.
            if preferenceIsManaged(key) { continue }
            CFPreferencesSetValue(
                key as CFString,
                child.value as CFPropertyList,
                appID,
                kCFPreferencesAnyUser,
                kCFPreferencesAnyHost
            )
        } else {
            defaults.set(child.value, forKey: key)
        }
    }

    if isRoot {
        // Ensure values are written to /Library/Preferences
        CFPreferencesSynchronize(appID, kCFPreferencesAnyUser, kCFPreferencesAnyHost)
    } else {
        // Usually not necessary, but harmless if you want immediate flush
        defaults.synchronize()
    }
}

func loadOutsetPreferences() -> OutsetPreferences {

    if debugMode {
        showPreferencePath("Load")
    }

    let defaults = UserDefaults.standard
    var outsetPrefs = OutsetPreferences()

    if isRoot {
        // A configuration profile wins; otherwise /Library/Preferences, never
        // root's own preference file; otherwise the default.
        outsetPrefs.networkTimeout = intPreference(rootPreferenceValue("network_timeout")) ?? 180
        outsetPrefs.ignoredUsers = rootPreferenceValue("ignored_users") as? [String] ?? []
        outsetPrefs.overrideLoginOnce = rootPreferenceValue("override_login_once") as? RunOnce ?? [:]
        outsetPrefs.waitForNetwork = boolPreference(rootPreferenceValue("wait_for_network"), defaultValue: defaultWaitForNetwork)
        outsetPrefs.backgroundScriptTimeout = intPreference(rootPreferenceValue("background_script_timeout")) ?? defaultBackgroundScriptTimeout
        // manifest_signing_key is only honoured when MDM-managed (forced). A locally
        // written key could be used to disable script processing without detection,
        // so we ignore it unless it comes from a managed profile. In debug mode a
        // local value is accepted to allow workflow testing without an MDM enrolment.
        let signingKeyManaged = preferenceIsManaged("manifest_signing_key")
        // An empty key is no key: it would otherwise require a signature that
        // nothing can satisfy and skip every script.
        let signingKey = nonEmpty(rootPreferenceValue("manifest_signing_key") as? String)
        if signingKeyManaged || debugMode {
            outsetPrefs.manifestSigningKey = signingKey ?? ""
            if !signingKeyManaged {
                writeLog("manifest_signing_key is not MDM-managed — accepted in debug mode only", logLevel: .debug)
            }
        } else if signingKey != nil {
            writeLog("manifest_signing_key is present but not MDM-managed — ignoring to prevent tampering", logLevel: .error)
        }
    } else {
        // load preferences for the current user, which includes /Library/Preferences
        outsetPrefs.networkTimeout = intPreference(defaults.object(forKey: "network_timeout")) ?? 180
        outsetPrefs.ignoredUsers = defaults.array(forKey: "ignored_users") as? [String] ?? []
        outsetPrefs.overrideLoginOnce = defaults.object(forKey: "override_login_once") as? RunOnce ?? [:]
        outsetPrefs.waitForNetwork = boolPreference(defaults.object(forKey: "wait_for_network"), defaultValue: defaultWaitForNetwork)
        if defaults.object(forKey: "background_script_timeout") != nil {
            outsetPrefs.backgroundScriptTimeout = defaults.integer(forKey: "background_script_timeout")
        }
        outsetPrefs.manifestSigningKey = nonEmpty(defaults.string(forKey: "manifest_signing_key")) ?? ""
    }
    return outsetPrefs
}

/// Whether a configuration profile sets this outset key.
func preferenceIsManaged(_ key: String) -> Bool {
    CFPreferencesAppValueIsForced(key as CFString, Bundle.main.bundleIdentifier! as CFString)
}

/// The value a root run uses: the profile's value when the key is managed,
/// otherwise /Library/Preferences. Root's own preference file is never read.
func rootPreferenceValue(_ key: String) -> Any? {
    resolvePreferenceValue(
        isManaged: preferenceIsManaged(key),
        managedValue: { CFPreferencesCopyAppValue(key as CFString, Bundle.main.bundleIdentifier! as CFString) },
        systemValue: { CFPreferencesCopyValue(key as CFString, Bundle.main.bundleIdentifier! as CFString, kCFPreferencesAnyUser, kCFPreferencesAnyHost) }
    )
}

/// Profile first, then the system-wide file, then nothing (the caller's default).
func resolvePreferenceValue(isManaged: Bool, managedValue: () -> Any?, systemValue: () -> Any?) -> Any? {
    if isManaged, let value = managedValue() { return value }
    return systemValue()
}

func nonEmpty(_ string: String?) -> String? {
    guard let string, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return string
}

// Interprets a raw CFPreferences value as a boolean. Key presence alone must
// never be treated as true: writeOutsetPreferences persists every key on boot,
// so the key exists on all installations regardless of its value.
func boolPreference(_ rawValue: Any?, defaultValue: Bool) -> Bool {
    return rawValue as? Bool ?? defaultValue
}

/// Reads a preference as an integer from a number or a numeric string.
func intPreference(_ value: Any?) -> Int? {
    switch value {
    case let int as Int: return int
    case let number as NSNumber: return number.intValue
    case let string as String: return Int(string.trimmingCharacters(in: .whitespaces))
    default: return nil
    }
}

/// Loads the run-once records for the current context.
///
/// - Parameter machineScoped: `true` for contexts whose records apply to the
///   machine as a whole (the boot contexts), which use the bare `run_once` key.
///   `false` - the default - scopes records to the console user under
///   `run_once-<username>`. This must reflect the payload context, not merely
///   whether the process is running as root: the privileged login contexts also
///   run as root but record per-user.
func loadRunOncePlist(machineScoped: Bool = false) -> RunOnce {

    if debugMode {
        showPreferencePath("Load")
    }

    let defaults = UserDefaults.standard
    var runOnceKey = "run_once"

    if isRoot {
        if !machineScoped {
            runOnceKey += "-"+getConsoleUserInfo().username
        }
        return CFPreferencesCopyValue(runOnceKey as CFString, Bundle.main.bundleIdentifier! as CFString, kCFPreferencesAnyUser, kCFPreferencesAnyHost) as? RunOnce ?? [:]
    } else {
        return defaults.object(forKey: runOnceKey) as? RunOnce ?? [:]
    }
}

/// Persists the run-once records for the current context.
///
/// - Parameter machineScoped: see `loadRunOncePlist(machineScoped:)`. Loads and
///   writes for the same context must always agree, or records are written to a
///   key that is never read back.
func writeRunOncePlist(runOnceData: RunOnce, machineScoped: Bool = false) {

    if debugMode {
        showPreferencePath("Stor")
    }

    let defaults = UserDefaults.standard
    var runOnceKey = "run_once"

    if isRoot {
        if !machineScoped {
            runOnceKey += "-"+getConsoleUserInfo().username
        }
        CFPreferencesSetValue(runOnceKey as CFString,
                              runOnceData as CFPropertyList,
                              Bundle.main.bundleIdentifier! as CFString,
                              kCFPreferencesAnyUser,
                              kCFPreferencesAnyHost)
    } else {
        defaults.set(runOnceData, forKey: runOnceKey)
    }
}

func showPreferencePath(_ action: String) {
    var prefsPath: String
    if isRoot {
        prefsPath = "/Library/Preferences".appending("/\(Bundle.main.bundleIdentifier!).plist")
    } else {
        let path = NSSearchPathForDirectoriesInDomains(.libraryDirectory, .userDomainMask, true)
        prefsPath = path[0].appending("/Preferences").appending("/\(Bundle.main.bundleIdentifier!).plist")
    }
    writeLog("\(action)ing preference file: \(prefsPath)", logLevel: .debug)
}
