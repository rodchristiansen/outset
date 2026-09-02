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

/// Creates the managed log directory root:wheel mode 1777 when it is missing and
/// restores that mode if it drifted. Root only; a no-op in user context.
func ensureManagedLogDirectory() {
    guard getuid() == 0 else { return }
    var info = stat()
    if stat(managedLogDirectory, &info) == 0 {
        if (info.st_mode & S_IFMT) == S_IFDIR, (info.st_mode & 0o7777) != managedLogDirectoryMode {
            chmod(managedLogDirectory, managedLogDirectoryMode)
        }
        return
    }
    let parent = (managedLogDirectory as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true,
                                             attributes: [FileAttributeKey.posixPermissions: 0o755])
    if mkdir(managedLogDirectory, managedLogDirectoryMode) == 0 {
        chown(managedLogDirectory, 0, 0)
        chmod(managedLogDirectory, managedLogDirectoryMode)
    }
}

/// True when the managed log directory exists (root creates it first) and this
/// process may create files in it.
func managedLogDirectoryIsWritable() -> Bool {
    ensureManagedLogDirectory()
    var info = stat()
    guard stat(managedLogDirectory, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return false }
    return access(managedLogDirectory, W_OK | X_OK) == 0
}

/// Creates the directory holding `path` if it is missing. Returns `false` if it could not be created.
func ensureLogDirectory(for path: String = logFilePath) -> Bool {
    let directory = (path as NSString).deletingLastPathComponent
    if directory == managedLogDirectory {
        ensureManagedLogDirectory()
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
/// is not a regular file with one link, and widens a file this process owns to
/// mode 0666 so the other context can append too. Returns `nil` on failure.
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
    let logEntry = formatLogFileLine(message, logLevel: logLevel) + "\n"
    guard let data = logEntry.data(using: .utf8) else { return }
    let preferred = logFilePath
    if appendToLogFile(data, at: preferred) {
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

func performLogRotation(logFolderPath: String, logFileBaseName: String, maxLogFiles: Int = 30) {
    let fileManager = FileManager.default

    // Check if the date has changed since the current log file was created
    let newestLogFile = logFolderPath + "/" + logFileBaseName
    // In the shared sticky directory only the owner (or root) may rename the file;
    // another context keeps appending to the current file instead.
    if fileManager.fileExists(atPath: newestLogFile), canRotateLogFile(newestLogFile) {
        let fileCreationDate = try? fileManager.attributesOfItem(atPath: newestLogFile)[.creationDate] as? Date
        if let creationDate = fileCreationDate {
            if !Calendar.current.isDate(creationDate, inSameDayAs: Date()) {
                // rotate files
                for archivedLogFile in (1...maxLogFiles).reversed() {
                    let sourcePath = logFolderPath + "/" + (archivedLogFile == 1 ? logFileBaseName : "\(logFileBaseName).\(archivedLogFile-1)")
                    let destinationPath = logFolderPath + "/" + "\(logFileBaseName).\(archivedLogFile)"

                    if fileManager.fileExists(atPath: sourcePath) {
                        if archivedLogFile == maxLogFiles {
                            // Delete the oldest log file if it exists
                            try? fileManager.removeItem(atPath: sourcePath)
                        } else {
                            // Move the log file to the next number in the rotation
                            try? fileManager.moveItem(atPath: sourcePath, toPath: destinationPath)
                        }
                    }
                }
                writeLog("Logrotate complete", logLevel: .debug)
            }
        }
    }
}
