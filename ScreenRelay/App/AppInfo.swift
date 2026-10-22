//
//  AppInfo.swift
//  ScreenRelay
//
//  The edition and version shown in the app, so users can tell which build each Mac runs.
//

import Foundation

nonisolated enum AppInfo {
    /// This is the free, open-source edition.
    static let edition = "Basic"

    /// Marketing version, e.g. "1.0" (MARKETING_VERSION).
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    /// Build number, e.g. "1" (CURRENT_PROJECT_VERSION).
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    /// e.g. "Basic 1.0 (1)" — also sent to the other Mac when connecting.
    static var versionLabel: String { "\(edition) \(version) (\(build))" }

    /// e.g. "ScreenRelay Basic 1.0 (1)".
    static var fullName: String { "ScreenRelay \(versionLabel)" }
}
