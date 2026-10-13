//
//  SettingsView.swift
//  Managed State Keeper
//
//  Prefs tab: centred app header, then outset's preferences in two columns of
//  cards, then a read-only list of outset's launchd jobs. Settings a profile
//  manages show their managed value, disabled (gray), and only the profile
//  can change them; one banner under the header explains why, instead of a
//  caption on every field. Every other setting is editable, and Save asks for
//  an administrator before the helper writes it. When a profile manages every
//  setting the tab is simply read-only, with no Save.
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

                if viewModel.hasManagedSettings {
                    ProfileManagedBanner()
                }

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

                saveBar

                ServicesSection(
                    prefixes: ["io.macadmins.Outset"],
                    extraDaemonDirectories: [
                        Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons").path
                    ]
                )

                footer
            }
            .padding()
        }
        .onAppear {
            viewModel.configure(client: xpcClient)
            viewModel.load()
            // AppKit makes the first key view first responder when the window
            // opens, which draws a focus ring on a control nobody chose. Start
            // with nothing focused; Tab still reaches every control.
            DispatchQueue.main.async {
                (NSApp.keyWindow ?? NSApp.mainWindow)?.makeFirstResponder(nil)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Text("v\(marketingVersion) (\(buildNumber))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Link("Documentation", destination: URL(string: "https://github.com/rodchristiansen/outset#readme")!)
                .font(.caption)
            Link("Report Issue", destination: URL(string: "https://github.com/macadmins/outset/issues")!)
                .font(.caption)
            Spacer()
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
        }
        .padding(.top, 8)
    }

    // MARK: - Save

    /// Status, then Revert and Save. Absent when a profile manages every
    /// setting, since nothing here can change.
    @ViewBuilder
    private var saveBar: some View {
        if !viewModel.isFullyManaged {
            HStack(spacing: 12) {
                saveStatusLabel
                Spacer()
                Button("Revert") {
                    viewModel.revert()
                }
                .disabled(!viewModel.hasUnsavedChanges || viewModel.saveStatus == .saving)
                .help("Discard the changes you have not saved")

                Button("Save") {
                    Task { await viewModel.save() }
                }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.hasUnsavedChanges || viewModel.saveStatus == .saving)
                .help("An administrator name and password is needed to save")
            }
        }
    }

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
        }
    }
}
