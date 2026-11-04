// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Netleash contributors

import Foundation

/// Stage before starting the installer: its source app may already live at /Applications/Netleash.app.
/// Copying first also lets the installer close the UI without losing its own payload.
func prepareInstaller() throws -> URL {
    let fm = FileManager.default
    let files = ["install.sh", "uninstall.sh", "panic.sh", "resume.sh", "netleash", "netleash-exec", "netleash-spawn"]
    let bundled = Bundle.main.resourceURL?.appendingPathComponent("Installer")
    let adjacent = Bundle.main.bundleURL.deletingLastPathComponent()
    guard let source = [bundled, adjacent].compactMap({ $0 }).first(where: { folder in
        files.allSatisfy { fm.isExecutableFile(atPath: folder.appendingPathComponent($0).path) }
    }), Bundle.main.bundleURL.pathExtension == "app" else {
        throw ShortcutError.message(L("This copy is incomplete. Open Netleash from a complete release or rebuild the app."))
    }
    let root = fm.temporaryDirectory.appendingPathComponent("netleash-install-" + UUID().uuidString)
    #if arch(arm64)
    let stage = root.appendingPathComponent("netleash-darwin-arm64")
    #else
    let stage = root.appendingPathComponent("netleash-darwin-amd64")
    #endif
    do {
        try fm.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for file in files { try fm.copyItem(at: source.appendingPathComponent(file), to: stage.appendingPathComponent(file)) }
        try fm.copyItem(at: Bundle.main.bundleURL, to: stage.appendingPathComponent("Netleash.app"))
        return stage.appendingPathComponent("install.sh")
    } catch {
        try? fm.removeItem(at: root)
        throw error
    }
}

func removePreparedInstaller(_ installer: URL) {
    try? FileManager.default.removeItem(at: installer.deletingLastPathComponent().deletingLastPathComponent())
}

/// Use the same terminal-less AppleScript transport as the install button, without administrator access.
/// The backend runs only its own temporary probe script; it does not run the real install.sh.
func checkInstallerTransport(_ installer: URL) throws {
    let runner = installer.deletingLastPathComponent().appendingPathComponent("netleash")
    let command = [runner.path, "installer-check"].map(shellQuote).joined(separator: " ")
    let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    var error: NSDictionary?
    guard let script = NSAppleScript(source: "do shell script \"\(escaped)\"") else {
        throw ShortcutError.message(L("Could not request administrator access."))
    }
    let result = script.executeAndReturnError(&error)
    if let error { throw ShortcutError.message("\(error[NSAppleScript.errorMessage] ?? error)") }
    guard result.stringValue?.hasPrefix("OK:") == true else { throw ShortcutError.message("installer launch probe returned no result") }
}
