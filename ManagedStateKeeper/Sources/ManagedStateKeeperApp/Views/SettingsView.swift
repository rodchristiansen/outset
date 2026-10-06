//
//  SettingsView.swift
//  Managed State Keeper
//
//  Prefs tab: centred app header, then outset's preferences in two columns of
//  cards. Managed settings show their managed value, locked.
//

import SwiftUI
import ManagedStateKeeperXPC

struct SettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    @Environment(XPCClient.self) private var xpcClient

    private var marketingVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "–"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                appInfoHeader

                Divider()

                HStack(alignment: .top, spacing: 20) {
                    VStack(spacing: 16) {
                        startupSection
                        scriptsSection
                    }
                    .frame(maxWidth: .infinity, alignment: .top)

                    VStack(spacing: 16) {
                        usersSection
                        loggingSection
                        signingSection
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }

                HStack {
                    Spacer()
                    saveStatusLabel
                }
                .padding(.top, 4)
            }
            .padding()
        }
        .onAppear {
            viewModel.configure(client: xpcClient)
            viewModel.load()
        }
    }

    // MARK: - App Info Header

    @ViewBuilder
    private var appInfoHeader: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 72, height: 72)

            Text("Managed State Keeper")
                .font(.largeTitle.bold())

            Text("Runs scripts and packages at boot, at login and on demand to keep each Mac in its managed state.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                Link("Documentation", destination: URL(string: "https://github.com/rodchristiansen/outset#readme")!)
                    .font(.caption)
                Link("Report Issue", destination: URL(string: "https://github.com/macadmins/outset/issues")!)
                    .font(.caption)
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Auto-Save Status

    @ViewBuilder
    private var saveStatusLabel: some View {
        switch viewModel.saveStatus {
        case .idle:
            EmptyView()
        case .saving:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Saving").font(.callout).foregroundStyle(.secondary)
            }
        case .saved:
            Label("Saved", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
                .transition(.opacity)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.callout)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var startupSection: some View {
        card("Startup", systemImage: "power") {
            settingRow(.waitForNetwork) {
                Toggle("Wait for the network before running boot items", isOn: $viewModel.waitForNetwork)
            }
            settingRow(.networkTimeout, label: "Network timeout") {
                numberField(value: $viewModel.networkTimeout, range: 0...3600, step: 10, unit: "seconds")
            }
        }
    }

    @ViewBuilder
    private var scriptsSection: some View {
        card("Scripts", systemImage: "terminal") {
            settingRow(.backgroundScriptTimeout, label: "Background script timeout") {
                numberField(value: $viewModel.backgroundScriptTimeout, range: 0...86_400, step: 60, unit: "seconds, 0 for no limit")
            }
        }
    }

    @ViewBuilder
    private var usersSection: some View {
        card("Users", systemImage: "person.2") {
            settingRow(.ignoredUsers, label: "Ignored users") {
                TextField("admin, support", text: $viewModel.ignoredUsersText)
                    .textFieldStyle(.roundedBorder)
            }
            Text("Login items never run for these accounts.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var loggingSection: some View {
        card("Logging", systemImage: "doc.text") {
            settingRow(.verboseLogging) {
                Toggle("Enable verbose logging", isOn: $viewModel.verboseLogging)
            }
        }
    }

    @ViewBuilder
    private var signingSection: some View {
        card("Script signing", systemImage: "signature") {
            VStack(alignment: .leading, spacing: 2) {
                Text("Signing key")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                switch viewModel.signingKeyState {
                case .managed:
                    Text("Set; every script must carry a valid signature.")
                    Label("Managed", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .ignored:
                    Text("Set outside a configuration profile, so outset ignores it.")
                        .foregroundStyle(.orange)
                case .notSet:
                    Text("Not set; scripts run without a signature check.")
                }
            }
            Text("Only a configuration profile can set the signing key.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Building Blocks

    @ViewBuilder
    private func card<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        } label: {
            Label(title, systemImage: systemImage)
                .font(.headline)
        }
    }

    @ViewBuilder
    private func numberField(value: Binding<Int>, range: ClosedRange<Int>, step: Int, unit: String) -> some View {
        HStack(spacing: 6) {
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 60)
            Stepper("", value: value, in: range, step: step)
                .labelsHidden()
            Text(unit)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Managed Setting Row

    @ViewBuilder
    private func settingRow<Content: View>(
        _ key: OutsetPreferenceKey,
        label: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let managed = viewModel.isManaged(key)
        VStack(alignment: .leading, spacing: 2) {
            if let label {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            content()
                .disabled(managed)
            if managed {
                Label("Managed", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
