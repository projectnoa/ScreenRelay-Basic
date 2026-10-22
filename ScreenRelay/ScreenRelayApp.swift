//
//  ScreenRelayApp.swift
//  ScreenRelay
//
//  Created by Juan Reyes on 10/20/26.
//

import SwiftUI

@main
struct ScreenRelayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        // ScreenRelay is a menu bar app (LSUIElement): no Dock icon unless a stream is showing.
        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            Image(nsImage: model.menuBarIcon)
        }
        .menuBarExtraStyle(.window)
        // The settings window is managed by AppModel (see showMainWindow).
    }
}
