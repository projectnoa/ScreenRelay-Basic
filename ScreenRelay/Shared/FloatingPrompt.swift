//
//  FloatingPrompt.swift
//  ScreenRelay
//
//  A small floating window for things that need attention right away (the pairing
//  code on the display, the code entry on the host). ScreenRelay lives in the menu
//  bar, so there may be no other window to put them in.
//

import AppKit
import SwiftUI

final class FloatingPrompt {
    private var panel: NSPanel?

    func show<Content: View>(title: String, @ViewBuilder content: () -> Content) {
        dismiss()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 200),
                            styleMask: [.titled, .closable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.title = title
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: content().padding(24).frame(minWidth: 320))
        panel.setContentSize(panel.contentView?.fittingSize ?? NSSize(width: 360, height: 200))
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func dismiss() {
        panel?.close()
        panel = nil
    }
}
