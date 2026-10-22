//
//  AppModel.swift
//  ScreenRelay
//
//  App-wide state. ScreenRelay lives in the menu bar, so the host or target controller
//  runs from launch to quit regardless of which windows are open.
//

import AppKit
import Combine
import ServiceManagement
import SwiftUI

final class AppModel: ObservableObject {
    static let shared = AppModel()

    let host = HostController()
    let target = TargetController()

    @Published var role: RelayRole? = RelayRole(rawValue: UserDefaults.standard.string(forKey: "role") ?? "") {
        didSet {
            UserDefaults.standard.set(role?.rawValue ?? "", forKey: "role")
            activateRole()
            mainWindow?.title = windowTitle
        }
    }

    /// The settings window. Managed in AppKit rather than as a SwiftUI scene so it can be
    /// opened from anywhere: first launch, reopening the app, or the menu bar.
    private var mainWindow: NSWindow?

    func showMainWindow() {
        if mainWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = windowTitle
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: ContentView(model: self))
            window.setContentSize(NSSize(width: 520, height: 680))
            window.center()
            window.setFrameAutosaveName("ScreenRelayMainWindow")
            mainWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    private var windowTitle: String {
        role.map { "ScreenRelay \(AppInfo.edition) — \($0.title)" } ?? "ScreenRelay \(AppInfo.edition)"
    }

    /// Mirrors System Settings › General › Login Items.
    @Published private(set) var launchesAtLogin = SMAppService.mainApp.status == .enabled
    @Published private(set) var launchAtLoginError: String?

    private var activeRole: RelayRole?

    /// Starts whichever side this Mac plays; called at launch and when the role changes.
    func activateRole() {
        guard role != activeRole else { return }
        switch activeRole {
        case .host:
            host.disconnect()
            host.stopBrowsing()
        case .target:
            target.stop()
        case nil:
            break
        }
        activeRole = role
        switch role {
        case .host: host.startBrowsing()
        case .target: target.start()
        case nil: break
        }
    }

    func setLaunchesAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        launchesAtLogin = SMAppService.mainApp.status == .enabled
        if enabled, SMAppService.mainApp.status == .requiresApproval {
            launchAtLoginError = "Allow ScreenRelay in System Settings › General › Login Items."
        }
    }

    /// The menu bar icon: the relay on a host, the monitor on a display.
    var menuBarIcon: NSImage {
        Self.templateImage(named: role == .host ? "relay" : "monitor")
    }

    private static func templateImage(named name: String) -> NSImage {
        let source = NSImage(named: name)
            ?? NSImage(systemSymbolName: "display", accessibilityDescription: "ScreenRelay")
            ?? NSImage()
        // The artwork is 512 px; menu bar icons are about 18 points tall.
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            source.draw(in: rect)
            return true
        }
        image.isTemplate = true // adapts to light/dark menu bars and highlighting
        image.accessibilityDescription = "ScreenRelay"
        return image
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Posted by a second copy of the app to the one already running.
    private static let showWindowNotification = Notification.Name("com.buildthestack.ScreenRelay.showWindow")

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Only one ScreenRelay may run (two would fight over the ports and the display).
        // A second launch — e.g. another copy of the app — hands over to the first and quits.
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0 != NSRunningApplication.current }
        if !others.isEmpty {
            DistributedNotificationCenter.default().postNotificationName(Self.showWindowNotification, object: nil,
                                                                         userInfo: nil, deliverImmediately: true)
            NSApp.terminate(nil)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DistributedNotificationCenter.default().addObserver(forName: Self.showWindowNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppModel.shared.showMainWindow() }
        }
        let model = AppModel.shared
        model.activateRole()
        // First launch: show the window so the role can be chosen. Otherwise stay quietly
        // in the menu bar (that's what happens when it starts at login).
        if model.role == nil {
            model.showMainWindow()
        }
    }

    /// Opening the app again (Finder, Spotlight, Launchpad) shows the window, since the
    /// menu bar icon can be hidden behind the notch on a crowded menu bar.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppModel.shared.showMainWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // keeps running in the menu bar
    }
}
