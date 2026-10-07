//
//  XPCClient.swift
//  Managed State Keeper
//
//  Manages the NSXPCConnection to the privileged helper daemon.
//  Streams outset's output back to the window and handles preference writes.
//

import Foundation
import ManagedStateKeeperXPC

@Observable
@MainActor
final class XPCClient: NSObject {
    var outputLines: [OutputLine] = []
    var isRunning = false
    var lastExitCode: Int32?
    var helperStatus: HelperStatus = .unknown
    var connectionError: String?

    private var connection: NSXPCConnection?

    struct OutputLine: Identifiable {
        let id = UUID()
        let text: String
        let level: LineLevel
    }

    enum HelperStatus: String {
        case unknown = "Unknown"
        case available = "Available"
        case unavailable = "Unavailable"
    }

    var errorCount: Int {
        outputLines.filter { $0.level == .error }.count
    }

    /// The newest line worth showing as the run's progress caption.
    var latestProgressLine: String? {
        outputLines.last { $0.level == .info || $0.level == .header }?.text
    }

    // MARK: - Connection Management

    func connect() {
        guard connection == nil else { return }

        let conn = NSXPCConnection(machServiceName: kHelperMachServiceName, options: .privileged)
        conn.remoteObjectInterface = .stateKeeperHelperInterface()
        conn.exportedInterface = NSXPCInterface(with: HelperXPCClientProtocol.self)
        conn.exportedObject = self

        conn.invalidationHandler = makeInvalidationHandler()
        conn.interruptionHandler = makeInterruptionHandler()

        conn.resume()
        connection = conn
        connectionError = nil

        // Ping the helper: the package installs it as a LaunchDaemon, so a reply
        // is the only check needed.
        helperProxy { [weak self] proxy in
            proxy.getHelperVersion { _ in
                Task { @MainActor [weak self] in
                    self?.helperStatus = .available
                    self?.connectionError = nil
                }
            }
        }
    }

    func disconnect() {
        connection?.invalidate()
        connection = nil
    }

    // MARK: - Runs

    func run(mode: RunMode) {
        guard !isRunning else { return }

        outputLines.removeAll()
        lastExitCode = nil
        connectionError = nil

        guard mode.runsInHelper else {
            triggerOnDemand()
            return
        }

        isRunning = true
        connect()
        helperProxy { proxy in
            proxy.run(mode: mode.rawValue)
        }
    }

    func stop() {
        helperProxy { proxy in
            proxy.stop()
        }
        isRunning = false
        lastExitCode = nil
        outputLines.append(OutputLine(text: "WARN: Run stopped by user.", level: .warning))
    }

    /// On-demand items run as the signed-in user, through outset's own
    /// LaunchAgent, which starts when its trigger file appears. The user can
    /// create that file, so no privilege is involved.
    private func triggerOnDemand() {
        let path = StateKeeperConstants.onDemandTrigger
        if FileManager.default.fileExists(atPath: path) || FileManager.default.createFile(atPath: path, contents: nil) {
            outputLines.append(OutputLine(text: "INFO: Triggered outset's on-demand run in your session.", level: .info))
            outputLines.append(OutputLine(text: "INFO: That run writes its own log session; open the Logs tab to follow it.", level: .info))
            lastExitCode = 0
        } else {
            outputLines.append(OutputLine(text: "ERROR: Could not create the on-demand trigger at \(path).", level: .error))
            lastExitCode = 1
        }
    }

    // MARK: - Preference Management

    func setBoolPreference(key: OutsetPreferenceKey, value: Bool) async -> Bool {
        await callHelper { proxy, reply in proxy.setBoolPreference(key: key.rawValue, value: value, withReply: reply) }
    }

    func setIntPreference(key: OutsetPreferenceKey, value: Int) async -> Bool {
        await callHelper { proxy, reply in proxy.setIntPreference(key: key.rawValue, value: value, withReply: reply) }
    }

    func setArrayPreference(key: OutsetPreferenceKey, value: [String]) async -> Bool {
        await callHelper { proxy, reply in proxy.setArrayPreference(key: key.rawValue, value: value, withReply: reply) }
    }

    func removePreference(key: OutsetPreferenceKey) async -> Bool {
        await callHelper { proxy, reply in proxy.removePreference(key: key.rawValue, withReply: reply) }
    }

    // MARK: - Private

    /// Calls the helper and waits for its reply; a refused or broken connection
    /// counts as a failed write rather than leaving the caller waiting.
    private func callHelper(
        _ body: @escaping @Sendable (HelperXPCProtocol, @escaping @Sendable (Bool) -> Void) -> Void
    ) async -> Bool {
        connect()
        guard let conn = connection else { return false }
        return await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            guard let proxy = conn.remoteObjectProxyWithErrorHandler({ _ in once.resume(false) }) as? HelperXPCProtocol else {
                once.resume(false)
                return
            }
            body(proxy) { ok in once.resume(ok) }
        }
    }

    /// Creates XPC callbacks in a nonisolated context so they don't inherit
    /// @MainActor isolation and crash when called on the XPC dispatch queue.
    private nonisolated func makeInvalidationHandler() -> @Sendable () -> Void {
        { [weak self] in
            Task { @MainActor [weak self] in
                self?.connection = nil
                self?.helperStatus = .unavailable
                self?.reportConnectionFailure("Connection to helper was invalidated")
            }
        }
    }

    private nonisolated func makeInterruptionHandler() -> @Sendable () -> Void {
        { [weak self] in
            Task { @MainActor [weak self] in
                self?.reportConnectionFailure("Connection to helper was interrupted")
            }
        }
    }

    private nonisolated func makeErrorHandler() -> @Sendable (any Error) -> Void {
        { [weak self] error in
            Task { @MainActor [weak self] in
                self?.reportConnectionFailure(error.localizedDescription)
            }
        }
    }

    /// A failed connection during a run must show up in the run output, in red.
    private func reportConnectionFailure(_ message: String) {
        connectionError = message
        if isRunning {
            outputLines.append(OutputLine(text: "ERROR: \(message). The helper refused the connection or is not running; see the system log for io.macadmins.Outset.helper.", level: .error))
            isRunning = false
        }
    }

    private func helperProxy(block: @escaping (HelperXPCProtocol) -> Void) {
        guard let conn = connection else {
            connectionError = "No connection to helper"
            return
        }
        guard let proxy = conn.remoteObjectProxyWithErrorHandler(makeErrorHandler()) as? HelperXPCProtocol else {
            connectionError = "Failed to get helper proxy"
            return
        }
        block(proxy)
    }
}

/// Resumes a continuation exactly once, whichever of the reply or the
/// connection error arrives first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Bool) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

// MARK: - HelperXPCClientProtocol

extension XPCClient: HelperXPCClientProtocol {

    nonisolated func didReceiveOutput(_ line: String) {
        let level = LineLevel.classify(line)
        Task { @MainActor in
            outputLines.append(OutputLine(text: line, level: level))
        }
    }

    nonisolated func runDidComplete(success: Bool, exitCode: Int32) {
        Task { @MainActor in
            isRunning = false
            lastExitCode = exitCode
        }
    }

    nonisolated func didEncounterError(_ message: String) {
        Task { @MainActor in
            connectionError = message
            outputLines.append(OutputLine(text: "ERROR: \(message)", level: .error))
        }
    }
}
