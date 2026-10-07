//
//  Logging.swift
//  Outset
//
//  Created by Bart E Reardon on 5/9/2023.
//

import Foundation
import OSLog

// swiftlint:disable force_try
class StandardError: TextOutputStream {
    func write(_ string: String) {
      if #available(macOS 10.15.4, *) {
          try! FileHandle.standardError.write(contentsOf: Data(string.utf8))
      } else {
          // Fallback on earlier versions (should work on pre 10.15.4 but untested)
          if let data = string.data(using: .utf8) {
              FileHandle.standardError.write(data)
          }
      }
    }
}
// swiftlint:enable force_try

func oslogTypeToString(_ type: OSLogType) -> String {
    switch type {
    case OSLogType.default: return "default"
    case OSLogType.info: return "info"
    case OSLogType.debug: return "debug"
    case OSLogType.error: return "error"
    case OSLogType.fault: return "fault"
    default: return "unknown"
    }
}

/// Maps an `OSLogType` onto the log file level vocabulary (DEBUG, INFO, WARN, ERROR).
func logFileLevel(_ type: OSLogType) -> String {
    switch type {
    case OSLogType.debug: return "DEBUG"
    case OSLogType.error, OSLogType.fault: return "ERROR"
    default: return "INFO"
    }
}

/// Formats a log file line as `[yyyy-MM-dd HH:mm:ss] LEVEL message` in local time,
/// with the level padded to five characters.
func formatLogFileLine(_ message: String, logLevel: OSLogType, date: Date = Date()) -> String {
    let dateFormatter = DateFormatter()
    dateFormatter.locale = Locale(identifier: "en_US_POSIX")
    dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let timestamp = dateFormatter.string(from: date)
    let level = logFileLevel(logLevel).padding(toLength: 5, withPad: " ", startingAt: 0)
    return "[\(timestamp)] \(level) \(message)"
}

// MARK: - Log locations

/// The per-user log root under `home`: ~/Library/Logs/Managed State.
func userLogDirectoryPath(home: String) -> String {
    return (home as NSString).appendingPathComponent(userLogSubpath)
}

/// Where this run logs. Root logs under the managed directory once it is locked;
/// every other context, and root when the managed directory cannot be trusted,
/// logs under its own home.
func resolveLogDirectory(isRoot: Bool, managedReady: Bool, userDirectory: String) -> String {
    return isRoot && managedReady ? managedLogDirectory : userDirectory
}

/// True when `path` is the managed log directory or inside it.
func isInsideManagedLogDirectory(_ path: String, root: String = managedLogDirectory) -> Bool {
    return path == root || path.hasPrefix(root + "/")
}

/// Prepared once per root process: the managed log directory exists, its chain
/// is trusted, and everything inside it is root's. Never evaluated in user context.
let managedLogDirectoryIsReady: Bool = {
    guard geteuid() == 0 else { return false }
    return prepareManagedLogDirectory()
}()

/// Root only. Locks the managed log directory and resets anything a
/// world-writable layout left inside it, then reports whether root may log there.
@discardableResult
func prepareManagedLogDirectory(_ path: String = managedLogDirectory,
                                ownedComponents: Int = managedLogOwnedComponents,
                                trustedOwners: Set<uid_t> = [0],
                                owner: uid_t = 0, group: gid_t = 0) -> Bool {
    let descriptor = openLockedLogDirectory(path, ownedComponents: ownedComponents,
                                            trustedOwners: trustedOwners, owner: owner, group: group)
    guard descriptor >= 0 else {
        printStdErr("ERROR: \(path) or a folder above it is a symlink or writable by others; not logging there")
        return false
    }
    defer { close(descriptor) }
    lockLogTree(descriptor, depth: 3, owner: owner, group: group)
    return true
}

/// Opens `path` one component at a time from "/", never following a symlink.
/// Folders above the last `ownedComponents` must be owned by a trusted owner and
/// writable by no group or other. The owned folders are created when missing and
/// set to `owner`:`group` mode 0755. Returns the final folder's descriptor, or -1
/// when any component is a symlink, not a folder, or not trusted.
func openLockedLogDirectory(_ path: String, ownedComponents: Int,
                            trustedOwners: Set<uid_t> = [0],
                            owner: uid_t = 0, group: gid_t = 0) -> Int32 {
    guard path.hasPrefix("/") else { return -1 }
    let components = path.split(separator: "/").map(String.init)
    guard !components.contains(".."), !components.contains("."), ownedComponents <= components.count else { return -1 }
    var current = open("/", O_RDONLY | O_DIRECTORY)
    guard current >= 0 else { return -1 }

    func isLocked(_ descriptor: Int32) -> Bool {
        var info = stat()
        return fstat(descriptor, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
            && trustedOwners.contains(info.st_uid) && info.st_mode & (S_IWGRP | S_IWOTH) == 0
    }

    guard isLocked(current) else { close(current); return -1 }
    for (index, component) in components.enumerated() {
        let owned = index >= components.count - ownedComponents
        if owned {
            _ = mkdirat(current, component, managedLogDirectoryMode)
        }
        // O_NOFOLLOW makes a symlink fail here rather than be walked through.
        let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        close(current)
        guard next >= 0 else { return -1 }
        current = next
        if owned {
            guard fchown(current, owner, group) == 0, fchmod(current, managedLogDirectoryMode) == 0 else {
                close(current)
                return -1
            }
        }
        guard isLocked(current) else { close(current); return -1 }
    }
    return current
}

/// Resets everything under the folder open at `directory` to root's: folders
/// `owner`:`group` 0755, files 0644. A folder is locked before its entries are
/// read, so no other account can add or swap an entry while the walk runs. A
/// symlink, a hard-linked file (which could share its inode with a file
/// elsewhere), or anything that is neither file nor folder is unlinked, never
/// followed or re-moded. Folders deeper than `depth` are left as they are.
func lockLogTree(_ directory: Int32, depth: Int, owner: uid_t = 0, group: gid_t = 0) {
    for name in OutsetSession.directoryEntryNames(directory) {
        var info = stat()
        guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            guard depth > 0 else { continue }
            let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard child >= 0 else { continue }
            if fchown(child, owner, group) == 0, fchmod(child, managedLogDirectoryMode) == 0 {
                lockLogTree(child, depth: depth - 1, owner: owner, group: group)
            }
            close(child)
        case S_IFREG:
            let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard file >= 0 else { continue }
            var opened = stat()
            if fstat(file, &opened) == 0, (opened.st_mode & S_IFMT) == S_IFREG, opened.st_nlink == 1 {
                _ = fchown(file, owner, group)
                _ = fchmod(file, managedLogFileMode)
                close(file)
            } else {
                close(file)
                unlinkat(directory, name, 0)
            }
        default:
            unlinkat(directory, name, 0)
        }
    }
}

/// Creates the directory holding `path` if it is missing. Returns `false` if it could not be created.
/// The managed log directory is root's alone: any other context is refused there.
func ensureLogDirectory(for path: String = logFilePath) -> Bool {
    let directory = (path as NSString).deletingLastPathComponent
    if isInsideManagedLogDirectory(directory) {
        guard geteuid() == 0, managedLogDirectoryIsReady else { return false }
        return checkDirectoryExists(path: directory)
    }
    if checkDirectoryExists(path: directory) {
        return true
    }
    do {
        let attributes = [FileAttributeKey.posixPermissions: 0o755]
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: attributes)
        return true
    } catch {
        printStdErr("\(oslogTypeToString(.error).uppercased()): Unable to create log directory at \(directory)")
        printStdErr(error.localizedDescription)
        return false
    }
}

/// Opens `path` for appending without following a symlink, refuses anything that
/// is not a regular file with one link, and sets a file this process owns to
/// mode 0644. Returns `nil` on failure.
func openLogFile(_ path: String) -> Int32? {
    let descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, managedLogFileMode)
    guard descriptor >= 0 else { return nil }
    var info = stat()
    guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else {
        close(descriptor)
        return nil
    }
    if info.st_uid == geteuid(), (info.st_mode & 0o777) != managedLogFileMode {
        fchmod(descriptor, managedLogFileMode)
    }
    return descriptor
}

/// Appends `data` to the log file at `path`. Returns `false` when the file could not be written.
func appendToLogFile(_ data: Data, at path: String) -> Bool {
    guard ensureLogDirectory(for: path), let descriptor = openLogFile(path) else { return false }
    defer { close(descriptor) }
    var ok = true
    data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
        guard let base = buffer.baseAddress else { return }
        var offset = 0
        while offset < buffer.count {
            let written = Darwin.write(descriptor, base + offset, buffer.count - offset)
            if written <= 0 { ok = false; break }
            offset += written
        }
    }
    return ok
}

/// True when this process may rename `path`: it is root, or it owns the file.
func canRotateLogFile(_ path: String) -> Bool {
    var info = stat()
    guard stat(path, &info) == 0 else { return false }
    return getuid() == 0 || info.st_uid == geteuid()
}

func printStdErr(_ errorMessage: String) {
    var standardError = StandardError()
    print(errorMessage, to: &standardError)
}

func printStdOut(_ message: String) {
    print(message)
}

func writeLog(_ message: String, logLevel: OSLogType = .info, log: OSLog = osLog) {
    // write to the system logs

    // let logger = Logger()  // 'Logger' is only available in macOS 11.0 or newer so we use os_log

    os_log("%{public}@", log: log, type: logLevel, message)
    switch logLevel {
    case .error, .debug, .fault:
        printStdErr("\(oslogTypeToString(logLevel).uppercased()): \(message)")
    default:
        printStdOut("\(oslogTypeToString(logLevel).uppercased()): \(message)")
    }

    // also write to a log file
    writeFileLog(message: message, logLevel: logLevel)
}

func writeFileLog(message: String, logLevel: OSLogType) {
    // write to a log file for accessability of those that don't want to manage the system log
    if logLevel == .debug && !debugMode {
        return
    }
    let now = Date()
    let logEntry = formatLogFileLine(message, logLevel: logLevel, date: now) + "\n"
    guard let data = logEntry.data(using: .utf8) else { return }
    let preferred = logFilePath
    if appendToLogFile(data, at: preferred) {
        // The same record, structured, in the session's events.jsonl.
        currentSession?.append(level: logFileLevel(logLevel), message: message, date: now)
        return
    }
    let fallback = userLogDirectory + "/" + logFileName
    if fallback != preferred, appendToLogFile(data, at: fallback) {
        return
    }
    printStdErr("\(oslogTypeToString(.error).uppercased()): Unable to write log file at \(preferred)")
}

func writeSysReport() {
    // Logs system information to log file
    writeLog("User: \(getConsoleUserInfo())", logLevel: .debug)
    writeLog("Model: \(deviceHardwareModel)", logLevel: .debug)
    writeLog("Marketing Model: \(marketingModel)", logLevel: .debug)
    writeLog("Serial: \(deviceSerialNumber)", logLevel: .debug)
    writeLog("OS: \(osVersion)", logLevel: .debug)
    writeLog("Build: \(osBuildVersion)", logLevel: .debug)
}
