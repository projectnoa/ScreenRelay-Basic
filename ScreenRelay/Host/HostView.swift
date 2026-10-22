//
//  HostView.swift
//  ScreenRelay
//

import SwiftUI

struct HostView: View {
    /// Owned by the app (it runs from the menu bar even with this window closed).
    @ObservedObject var controller: HostController
    @State private var manualAddress = ""

    var body: some View {
        Form {
            Section {
                statusRow
                if !controller.targetAppVersion.isEmpty {
                    LabeledContent("Display's app") {
                        if controller.targetVersionMismatch {
                            Label("\(controller.targetAppVersion) — this Mac runs \(AppInfo.versionLabel)",
                                  systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                                .help("Use the same build on both Macs to avoid surprises.")
                        } else {
                            Text(controller.targetAppVersion)
                        }
                    }
                }
                if !controller.pathDescription.isEmpty {
                    LabeledContent("Network", value: controller.pathDescription)
                }
                if !controller.streamDescription.isEmpty {
                    LabeledContent("Stream", value: controller.streamDescription)
                }
                if !controller.liveStats.isEmpty {
                    LabeledContent("Live") {
                        Text(controller.liveStats)
                            .monospacedDigit()
                            .multilineTextAlignment(.trailing)
                    }
                }
                if !controller.cursorStatus.isEmpty {
                    LabeledContent("Pointer", value: controller.cursorStatus)
                }
                if case .streaming = controller.phase {
                    LabeledContent("Link speed") {
                        HStack {
                            if !controller.linkSpeed.isEmpty {
                                Text(controller.linkSpeed)
                                    .multilineTextAlignment(.trailing)
                            }
                            Button("Test") { controller.testLinkSpeed() }
                                .disabled(controller.isTestingLink)
                                .help("Measures the connection for about 2 seconds; the picture pauses meanwhile.")
                        }
                    }
                }
                if controller.isActive {
                    Button("Disconnect", role: .destructive) {
                        controller.userDisconnect()
                    }
                }
            }

            if !controller.hasScreenRecordingPermission {
                Section {
                    Label("ScreenRelay needs Screen Recording permission to capture the extended display.",
                          systemImage: "exclamationmark.triangle")
                    Button("Grant Permission…") {
                        controller.requestScreenRecordingPermission()
                    }
                }
            }

            Section("Targets") {
                if controller.targets.isEmpty {
                    Text("Searching for Macs running ScreenRelay in Target mode…")
                        .foregroundStyle(.secondary)
                }
                ForEach(controller.targets) { target in
                    HStack {
                        Label(target.name, systemImage: "display")
                        Spacer()
                        Button("Connect") {
                            controller.connect(to: target)
                        }
                        .disabled(controller.isActive)
                    }
                }
                HStack {
                    TextField("Address", text: $manualAddress, prompt: Text("169.254.x.x or imac.local"))
                        .onSubmit { controller.connect(toAddress: manualAddress) }
                    Button("Connect") {
                        controller.connect(toAddress: manualAddress)
                    }
                    .disabled(manualAddress.isEmpty || controller.isActive)
                }
            }

            Section("Settings") {
                VStack(alignment: .leading) {
                    Slider(value: $controller.bitrateMbps, in: 5...100, step: 5) {
                        Text("Bitrate")
                    }
                    Text("\(Int(controller.bitrateMbps)) Mbps")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Picker("Picture", selection: $controller.pictureMode) {
                    Text("Automatic").tag(HostController.PictureMode.automatic)
                    Text("Native (BC7)").tag(HostController.PictureMode.native)
                    Text("Compressed (HEVC)").tag(HostController.PictureMode.compressed)
                }
                Text("Automatic streams native 5K over the Thunderbolt Bridge and falls back to compressed video otherwise. Applies to the next connection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Stream resolution", selection: $controller.streamScale) {
                    Text("100% (native)").tag(1.0)
                    Text("75%").tag(0.75)
                    Text("50%").tag(0.5)
                }
                Text("Lower resolutions are easier for older Macs to decode. Changing this or the display's resolution in System Settings applies immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Thunderbolt / wired only (never use Wi‑Fi)", isOn: $controller.wiredOnly)
                Toggle("Connect to the last display automatically", isOn: $controller.autoConnect)
                Text("Reconnects at login, after this Mac wakes, and whenever the display reappears.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Paired displays") {
                if controller.pairedTargets.isEmpty {
                    Text("None yet. The first connection to a display asks for the code it shows.")
                        .foregroundStyle(.secondary)
                }
                ForEach(controller.pairedTargets) { target in
                    HStack {
                        Label(target.name, systemImage: "lock.display")
                        Spacer()
                        Button("Forget", role: .destructive) { controller.forget(target) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var statusRow: some View {
        switch controller.phase {
        case .idle:
            Label("Not connected", systemImage: "circle")
        case let .connecting(name):
            Label {
                Text("Connecting to \(name)…")
            } icon: {
                ProgressView().controlSize(.small)
            }
        case let .pairing(name):
            Label("Enter the code shown on \(name)", systemImage: "lock.shield")
                .foregroundStyle(.orange)
        case let .streaming(name):
            Label("Extending display to \(name)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .failed(message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }
}

/// Asks for the code the display shows during pairing.
struct PairingEntryView: View {
    let targetName: String
    let error: String?
    let onSubmit: (String) -> Void
    let onCancel: () -> Void
    @State private var code = ""

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.system(size: 36))
                .foregroundStyle(.tint)
            Text("Pair with \(targetName)")
                .font(.headline)
            Text("Enter the 6-digit code shown on \(targetName).")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            TextField("Code", text: $code, prompt: Text("000 000"))
                .font(.system(size: 28, weight: .semibold, design: .monospaced))
                .multilineTextAlignment(.center)
                .frame(width: 180)
                .onSubmit(submit)
            if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Pair", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(code.filter(\.isNumber).count != 6)
            }
        }
    }

    private func submit() {
        guard code.filter(\.isNumber).count == 6 else { return }
        onSubmit(code)
    }
}
