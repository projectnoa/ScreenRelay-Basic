//
//  MenuBarContent.swift
//  ScreenRelay
//
//  The menu bar panel: status at a glance and the everyday controls. Everything else
//  lives in the main window ("Settings…").
//

import SwiftUI

struct MenuBarContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("ScreenRelay")
                    .font(.headline)
                Text(AppInfo.versionLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let role = model.role {
                    Text(role.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            switch model.role {
            case .host:
                HostMenuSection(controller: model.host)
            case .target:
                TargetMenuSection(controller: model.target)
            case nil:
                Text("Choose whether this Mac is the host or the display.")
                    .foregroundStyle(.secondary)
            }

            Divider()

            Toggle("Open at Login", isOn: Binding(
                get: { model.launchesAtLogin },
                set: { model.setLaunchesAtLogin($0) }
            ))
            if let error = model.launchAtLoginError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button(model.role == nil ? "Set Up…" : "Settings…") {
                    model.showMainWindow()
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}

private struct HostMenuSection: View {
    @ObservedObject var controller: HostController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch controller.phase {
            case .idle:
                Label("Not connected", systemImage: "circle")
            case let .connecting(name):
                Label("Connecting to \(name)…", systemImage: "ellipsis.circle")
            case let .pairing(name):
                Label("Enter the code shown on \(name)", systemImage: "lock.shield")
                    .foregroundStyle(.orange)
            case let .streaming(name):
                Label("Extending to \(name)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case let .failed(message):
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            if controller.isActive {
                Button("Disconnect") { controller.userDisconnect() }
            } else {
                ForEach(controller.targets) { target in
                    Button {
                        controller.connect(to: target)
                    } label: {
                        Label("Connect to \(target.name)", systemImage: "display")
                    }
                }
                if controller.targets.isEmpty {
                    Text("No displays found")
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("Connect automatically", isOn: $controller.autoConnect)
        }
    }
}

private struct TargetMenuSection: View {
    @ObservedObject var controller: TargetController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch controller.phase {
            case .stopped:
                Label("Not listening", systemImage: "circle")
            case .waiting:
                Label("Waiting for a host", systemImage: "antenna.radiowaves.left.and.right")
            case let .streaming(host):
                Label("Showing \(host)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Show Stream") { controller.showStream() }
            case let .failed(message):
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
            Toggle("Turn off with the host", isOn: $controller.sleepWithHost)
        }
    }
}
