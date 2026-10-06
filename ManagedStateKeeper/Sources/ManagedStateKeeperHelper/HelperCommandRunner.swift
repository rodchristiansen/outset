//
//  HelperCommandRunner.swift
//  ManagedStateKeeperHelper
//
//  Implements the XPC protocol: runs outset in a fixed mode with output
//  streaming, and writes outset's system-level preferences.
//

import Foundation
import ManagedStateKeeperXPC

final class HelperCommandRunner: NSObject, HelperXPCProtocol, @unchecked Sendable {
    // Safety invariant: `process` is only mutated on the XPC dispatch queue
    // which serializes all incoming calls. The connection holds a strong
    // reference to this object; invalidationHandler calls cancelRunningProcess
    // on the same queue.
    private let connection: NSXPCConnection
    private var process: Process?

    private static var domain: CFString { StateKeeperConstants.preferenceDomain as CFString }

    init(connection: NSXPCConnection) {
        self.connection = connection
    }

    // MARK: - Runs

    func run(mode: String) {
        let clientProxy = connection.remoteObjectProxy as? HelperXPCClientProtocol

        guard let runMode = RunMode(rawValue: mode), runMode.runsInHelper else {
            clientProxy?.didEncounterError("Unknown run mode: \(mode)")
            clientProxy?.runDidComplete(success: false, exitCode: -1)
            return
        }
        guard process == nil else {
            clientProxy?.didEncounterError("A run is already in progress.")
            return
        }
        let executable = StateKeeperConstants.outsetExecutablePath
        if let problem = Self.untrustedPathProblem(executable) {
            clientProxy?.didEncounterError("Refusing to run outset: \(problem)")
            clientProxy?.runDidComplete(success: false, exitCode: -1)
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = runMode.arguments
        task.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        process = task

        // Stream output line by line on a background queue
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty else {
                fileHandle.readabilityHandler = nil
                return
            }
            if let text = String(data: data, encoding: .utf8) {
                for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                    clientProxy?.didReceiveOutput(line)
                }
            }
        }

        task.terminationHandler = { [weak self] proc in
            handle.readabilityHandler = nil
            let remaining = handle.readDataToEndOfFile()
            if !remaining.isEmpty, let text = String(data: remaining, encoding: .utf8) {
                for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                    clientProxy?.didReceiveOutput(line)
                }
            }
            let exitCode = proc.terminationStatus
            clientProxy?.runDidComplete(success: exitCode == 0, exitCode: exitCode)
            self?.process = nil
        }

        do {
            try task.run()
        } catch {
            clientProxy?.didEncounterError("Failed to launch outset: \(error.localizedDescription)")
            clientProxy?.runDidComplete(success: false, exitCode: -1)
            process = nil
        }
    }

    func stop() {
        cancelRunningProcess()
    }

    func cancelRunningProcess() {
        process?.terminate()
        process = nil
    }

    /// Root runs only a binary that root alone can change: the file and every
    /// directory above it must be root-owned and not group- or world-writable,
    /// and none of them a symlink. Returns the reason when that does not hold.
    static func untrustedPathProblem(_ path: String) -> String? {
        var current = URL(fileURLWithPath: path).standardized.path
        while true {
            var info = stat()
            guard lstat(current, &info) == 0 else {
                return "\(current) does not exist"
            }
            if (info.st_mode & S_IFMT) == S_IFLNK {
                return "\(current) is a symbolic link"
            }
            if info.st_uid != 0 {
                return "\(current) is not owned by root"
            }
            if info.st_mode & (S_IWGRP | S_IWOTH) != 0 {
                return "\(current) is writable by users other than root"
            }
            if current == "/" { return nil }
            current = (current as NSString).deletingLastPathComponent
            if current.isEmpty { current = "/" }
        }
    }

    // MARK: - Preferences
    //
    // Writes land in /Library/Preferences/io.macadmins.Outset.plist
    // (any user, any host), the file the root engine reads. The domain is fixed
    // and only the keys the window edits are accepted.

    func setBoolPreference(key: String, value: Bool, withReply reply: @escaping (Bool) -> Void) {
        write(key: key, value: value as CFBoolean, reply: reply)
    }

    func setIntPreference(key: String, value: Int, withReply reply: @escaping (Bool) -> Void) {
        write(key: key, value: value as CFNumber, reply: reply)
    }

    func setArrayPreference(key: String, value: [String], withReply reply: @escaping (Bool) -> Void) {
        write(key: key, value: value as CFArray, reply: reply)
    }

    func removePreference(key: String, withReply reply: @escaping (Bool) -> Void) {
        write(key: key, value: nil, reply: reply)
    }

    private func write(key: String, value: CFPropertyList?, reply: @escaping (Bool) -> Void) {
        guard OutsetPreferenceKey.isWritable(key) else {
            reply(false)
            return
        }
        CFPreferencesSetValue(key as CFString, value, Self.domain, kCFPreferencesAnyUser, kCFPreferencesAnyHost)
        reply(CFPreferencesSynchronize(Self.domain, kCFPreferencesAnyUser, kCFPreferencesAnyHost))
    }

    // MARK: - Version

    func getHelperVersion(withReply reply: @escaping (String) -> Void) {
        reply(Self.bundleVersion)
    }

    /// The version of the app bundle the helper ships in.
    static let bundleVersion: String = {
        let ownPath = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let infoPlist = ownPath
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Info.plist")
        guard let info = NSDictionary(contentsOf: infoPlist) else { return "unknown" }
        let short = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? short : "\(short).\(build)"
    }()
}
