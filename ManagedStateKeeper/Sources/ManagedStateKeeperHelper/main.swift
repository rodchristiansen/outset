//
//  main.swift
//  ManagedStateKeeperHelper
//
//  Privileged XPC helper daemon. The package installs it as a system
//  LaunchDaemon; it runs outset in a fixed mode and writes outset's
//  system-level preferences for the Managed State Keeper window.
//

import Foundation
import os
import Security
import ManagedStateKeeperXPC

private let log = Logger(subsystem: "io.macadmins.Outset.helper", category: "xpc")

/// The Team ID this helper is signed with. The GUI is signed by the same
/// identity, so the helper trusts exactly its own team and needs no Team ID
/// baked into the source. Nil when the helper is unsigned or ad-hoc signed.
private let ownTeamID: String? = {
    var selfCode: SecCode?
    guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(selfCode, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let dict = info as? [String: Any] else { return nil }
    return dict[kSecCodeInfoTeamIdentifier as String] as? String
}()

final class HelperService: NSObject, NSXPCListenerDelegate, Sendable {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        // Only our own signed app may connect: its identifier, signed by this
        // helper's own team.
        guard let teamID = ownTeamID else {
            log.error("Rejecting XPC client pid \(connection.processIdentifier): this helper has no Team ID (unsigned or ad-hoc build)")
            return false
        }
        // The system checks the requirement against the client's audit token on
        // every message, so a recycled PID cannot impersonate the GUI.
        connection.setCodeSigningRequirement(
            "identifier \"\(StateKeeperConstants.appIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
        )
        log.info("Accepted XPC client pid \(connection.processIdentifier) subject to Team ID \(teamID, privacy: .public)")

        connection.exportedInterface = .stateKeeperHelperInterface()
        connection.remoteObjectInterface = NSXPCInterface(with: HelperXPCClientProtocol.self)

        let runner = HelperCommandRunner(connection: connection)
        connection.exportedObject = runner

        connection.invalidationHandler = { [weak runner] in
            runner?.cancelRunningProcess()
        }

        connection.resume()
        return true
    }
}

let delegate = HelperService()
let listener = NSXPCListener(machServiceName: kHelperMachServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
