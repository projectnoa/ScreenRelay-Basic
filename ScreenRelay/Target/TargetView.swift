//
//  TargetView.swift
//  ScreenRelay
//

import SwiftUI

struct TargetView: View {
    /// Owned by the app (it runs from the menu bar even with this window closed).
    @ObservedObject var controller: TargetController

    var body: some View {
        Form {
            Section {
                statusRow
                LabeledContent("Display name", value: controller.displayName)
                if case .streaming = controller.phase {
                    Button("Show Stream") { controller.showStream() }
                }
            }

            Section("Security and power") {
                Toggle("Allow hosts to connect over Wi‑Fi", isOn: $controller.allowWiFi)
                Text("Off: only Macs on the Thunderbolt Bridge (or Ethernet) can connect. Either way, only paired Macs are shown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Turn this display off when the host sleeps", isOn: $controller.sleepWithHost)
                Text("The panel turns on again when the host wakes and reconnects. While no host is connected, this Mac follows its own energy settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Paired hosts") {
                if controller.pairedHosts.isEmpty {
                    Text("None yet. A host pairs the first time it connects, using a code shown here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(controller.pairedHosts) { host in
                    HStack {
                        Label(host.name, systemImage: "lock.laptopcomputer")
                        Spacer()
                        Button("Forget", role: .destructive) { controller.forget(host) }
                    }
                }
            }

            Section("Addresses") {
                if controller.localAddresses.isEmpty {
                    Text("No network interfaces found")
                        .foregroundStyle(.secondary)
                }
                ForEach(controller.localAddresses, id: \.self) { address in
                    Text(address)
                        .textSelection(.enabled)
                        .monospaced()
                }
                Text("The host finds this Mac automatically. If it doesn't, enter the Thunderbolt Bridge address (usually 169.254.x.x on bridge0) on the host.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("When a host connects, the stream opens full screen in its own Space. Use this Mac's mouse and keyboard to reach its desktop: switch Spaces, press Esc to leave full screen, or ⌘M to minimize. Close the stream window to disconnect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var statusRow: some View {
        switch controller.phase {
        case .stopped:
            Label("Not listening", systemImage: "circle")
        case .waiting:
            Label {
                Text("Waiting for a host…")
            } icon: {
                ProgressView().controlSize(.small)
            }
        case let .streaming(host):
            Label("Showing screen from \(host)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .failed(message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }
}

#Preview {
    TargetView(controller: TargetController())
}
