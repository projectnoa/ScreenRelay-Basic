//
//  ContentView.swift
//  ScreenRelay
//
//  Created by Juan Reyes on 10/20/26.
//

import SwiftUI

enum RelayRole: String, CaseIterable, Identifiable {
    case host
    case target

    var id: String { rawValue }

    var title: String {
        switch self {
        case .host: "Host"
        case .target: "Target"
        }
    }

    var summary: String {
        switch self {
        case .host: "Extend this Mac's desktop onto another Mac."
        case .target: "Use this Mac's screen as a display for another Mac."
        }
    }

    var systemImage: String {
        switch self {
        case .host: "desktopcomputer"
        case .target: "display"
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel

    private var role: RelayRole? { model.role }

    var body: some View {
        Group {
            switch role {
            case .host:
                HostView(controller: model.host)
            case .target:
                TargetView(controller: model.target)
            case nil:
                RolePicker { model.role = $0 }
            }
        }
        .frame(minWidth: 460, minHeight: 360)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 16) {
                if let coffee = URL(string: "https://buymeacoffee.com/juanreyes") {
                    Link(destination: coffee) {
                        Label("Buy me a coffee", systemImage: "cup.and.saucer")
                    }
                }
                if let website = URL(string: "https://buildthestack.com") {
                    Link("buildthestack.com", destination: website)
                }
                Spacer()
                Text(AppInfo.fullName)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if role != nil {
                    Button("Change Role…") { model.role = nil }
                }
            }
            .font(.callout)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }
}

private struct RolePicker: View {
    let onSelect: (RelayRole) -> Void

    var body: some View {
        VStack(spacing: 24) {
            Text("How will this Mac be used?")
                .font(.title2.weight(.semibold))
            HStack(spacing: 16) {
                ForEach(RelayRole.allCases) { role in
                    Button {
                        onSelect(role)
                    } label: {
                        VStack(spacing: 12) {
                            Image(systemName: role.systemImage)
                                .font(.system(size: 40))
                            Text(role.title)
                                .font(.headline)
                            Text(role.summary)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(width: 180, height: 160)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(32)
    }
}

#Preview {
    ContentView(model: AppModel.shared)
}
