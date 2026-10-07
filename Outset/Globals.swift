//
//  Globals.swift
//  Outset
//
//  Created by Bart Reardon on 22/6/2024.
//
// swiftlint:disable line_length

import Foundation
import OSLog

// Clean this bit up and make it less C-ish and more Swifty

let author = "Bart Reardon - Adapted from outset by Joseph Chilcote (chilcote@gmail.com) https://github.com/chilcote/outset"
let outsetVersion: AnyObject = Bundle.main.infoDictionary!["CFBundleShortVersionString"] as AnyObject

// Outset specific directories
let outsetDirectory = "/usr/local/outset/"
let payloadDirectory = outsetDirectory+"payload/"

// Set some variables
var debugMode: Bool = false
var prefs = loadOutsetPreferences()

// Log Stuff
let bundleID = Bundle.main.bundleIdentifier ?? "io.macadmins.Outset"
let osLog = OSLog(subsystem: bundleID, category: "main")
// We could make these availab as preferences perhaps
let logFileName = "outset.log"
// Logs are split by context. A root run logs under the managed log directory,
// which only root can write: root:wheel 0755, files 0644, and no symlink
// anywhere in its folder chain. A user-context run (login-every, login-once,
// on-demand) logs under ~/Library/Logs/Managed State instead, in the same
// YYYY-MM-DD/HHMMSS/ layout, and never touches the managed directory.
let managedLogDirectory = "/Library/Managed State/logs"
/// Trailing components of `managedLogDirectory` that outset owns and locks:
/// "Managed State" and "logs". Everything above them must already be root-only.
let managedLogOwnedComponents = 2
let managedLogDirectoryMode: mode_t = 0o755
let managedLogFileMode: mode_t = 0o644
let userLogSubpath = "Library/Logs/Managed State"
var userLogDirectory: String {
    return userLogDirectoryPath(home: FileManager.default.homeDirectoryForCurrentUser.path)
}
var logDirectory: String {
    return resolveLogDirectory(isRoot: geteuid() == 0,
                               managedReady: geteuid() == 0 && managedLogDirectoryIsReady,
                               userDirectory: userLogDirectory)
}
/// The file this run's lines go to: its session directory's outset.log when the
/// run has a session, otherwise the flat log at the root, as builds before the
/// session layout wrote.
var logFilePath: String {
    if let session = currentSession {
        return session.logFilePath
    }
    return logDirectory + "/" + logFileName
}

let scriptPayloads = getScriptPayloads()

enum Trigger: String {
    case onDemand = "/private/tmp/.io.macadmins.outset.ondemand.launchd"
    case onDemandPrivileged = "/private/tmp/.io.macadmins.outset.ondemand-privileged.launchd"
    case loginPrivileged = "/private/tmp/.io.macadmins.outset.login-privileged.launchd"
    case cleanup = "/private/tmp/.io.macadmins.outset.cleanup.launchd"

    var path: String {
        return self.rawValue
    }
}

enum FilePermissions: NSNumber {
    case file = 0o644
    case executable = 0o755

    // Convenience property to access the raw value as an NSNumber
    var asNSNumber: NSNumber {
        return self.rawValue
    }
}

enum PayloadKeys: String {
    case loginWindow = "login-window"
    case loginOnce = "login-once"
    case loginEvery = "login-every"
    case loginPrivilegedOnce = "login-privileged-once"
    case loginPrivilegedEvery = "login-privileged-every"
    case bootOnce = "boot-once"
    case bootEvery = "boot-every"
    case onDemand = "on-demand"
    case onDemandPrivileged = "on-demand-privileged"
    case shared = "share"

    var key: String {
        return self.rawValue
    }
}

enum PayloadType {
    case loginWindow
    case loginOnce
    case loginEvery
    case loginPrivilegedOnce
    case loginPrivilegedEvery
    case bootOnce
    case bootEvery
    case onDemand
    case onDemandPrivileged
    case shared

    // Static property for the base directory, allowing dynamic updates
    private static var outsetDirectory: String {
        get {
            return UserDefaults.standard.string(forKey: "outsetDirectory") ?? "/usr/local/outset/"
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "outsetDirectory")
        }
    }

    // Static method to update the base directory
    static func updateOutsetDirectory(to newPath: String) {
        PayloadType.outsetDirectory = newPath
    }

    // Computed property to get the full directory path for each case
    var directoryPath: String {
        switch self {
        case .loginWindow:
            return PayloadType.outsetDirectory + PayloadKeys.loginWindow.key
        case .loginOnce:
            return PayloadType.outsetDirectory + PayloadKeys.loginOnce.key
        case .loginEvery:
            return PayloadType.outsetDirectory + PayloadKeys.loginEvery.key
        case .loginPrivilegedOnce:
            return PayloadType.outsetDirectory + PayloadKeys.loginPrivilegedOnce.key
        case .loginPrivilegedEvery:
            return PayloadType.outsetDirectory + PayloadKeys.loginPrivilegedEvery.key
        case .bootOnce:
            return PayloadType.outsetDirectory + PayloadKeys.bootOnce.key
        case .bootEvery:
            return PayloadType.outsetDirectory + PayloadKeys.bootEvery.key
        case .onDemand:
            return PayloadType.outsetDirectory + PayloadKeys.onDemand.key
        case .onDemandPrivileged:
            return PayloadType.outsetDirectory + PayloadKeys.onDemandPrivileged.key
        case .shared:
            return PayloadType.outsetDirectory + PayloadKeys.shared.key
        }
    }
    
    var isEmpty: Bool {
        return folderContents(type: self).isEmpty
    }

    var once: Bool {
        switch self {
        case .loginOnce, .bootOnce, .loginPrivilegedOnce:
            return true
        default:
            return false
        }
    }
}

// swiftlint:enable line_length
