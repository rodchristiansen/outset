//
//  ManagedStateKeeperApp.swift
//  Managed State Keeper
//
//  SwiftUI window for outset: its preferences, a manual run with live
//  output, and the log of every run.
//

import SwiftUI

@main
struct ManagedStateKeeperApp: App {
    @State private var xpcClient = XPCClient()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(xpcClient)
                .frame(minWidth: 700, minHeight: 500)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 850, height: 748)
    }
}
