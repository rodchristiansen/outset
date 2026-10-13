//
//  AdminAuthorization.swift
//  Managed State Keeper
//
//  Asks an administrator to authenticate when the user saves, and hands the
//  helper the resulting authorization, which it checks before every write.
//  The authorization lasts for one save only: it is destroyed afterwards, so
//  the next save asks again and the window never stays unlocked.
//

import Foundation
import Security
import ManagedStateKeeperXPC

/// Obtains an administrator's authorization for one save.
@MainActor
protocol AdminAuthorizing: AnyObject {
    /// Shows the system's administrator prompt. Returns the authorization's
    /// external form for the helper, or nil when the user cancelled or the
    /// credentials were not an administrator's.
    func authorize() -> Data?
    /// Destroys the authorization `authorize()` obtained.
    func release()
}

@MainActor
final class AdminAuthorization: AdminAuthorizing {
    private var authRef: AuthorizationRef?

    func authorize() -> Data? {
        release()
        var ref: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &ref) == errAuthorizationSuccess, let ref else { return nil }

        let status = StateKeeperConstants.adminRight.withCString { name -> OSStatus in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { itemPointer in
                var rights = AuthorizationRights(count: 1, items: itemPointer)
                return AuthorizationCopyRights(ref, &rights, nil, [.interactionAllowed, .extendRights, .preAuthorize], nil)
            }
        }
        guard status == errAuthorizationSuccess else {
            AuthorizationFree(ref, [])
            return nil
        }

        var form = AuthorizationExternalForm()
        guard AuthorizationMakeExternalForm(ref, &form) == errAuthorizationSuccess else {
            AuthorizationFree(ref, [.destroyRights])
            return nil
        }
        authRef = ref
        return withUnsafeBytes(of: &form) { Data($0) }
    }

    func release() {
        if let authRef {
            AuthorizationFree(authRef, [.destroyRights])
        }
        authRef = nil
    }
}
