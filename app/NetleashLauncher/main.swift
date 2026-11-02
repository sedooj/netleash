// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Netleash contributors
// A desktop shortcut hands the original bundle URL to the installed Netleash app.
// It never starts the target itself, even if protection or Netleash is unavailable.

import AppKit

func L(_ text: String) -> String { NSLocalizedString(text, comment: "") }

func fail(_ text: String) -> Never {
    let alert = NSAlert()
    alert.messageText = L("Could not open Netleash")
    alert.informativeText = text
    alert.alertStyle = .critical
    NSApp.activate(ignoringOtherApps: true)
    alert.runModal()
    exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
guard let path = Bundle.main.object(forInfoDictionaryKey: "NetleashTargetAppPath") as? String,
      path.hasPrefix("/"), path.hasSuffix(".app") else {
    fail(L("This shortcut has no target application."))
}
let netleash = URL(fileURLWithPath: "/Applications/Netleash.app")
guard let executable = Bundle(url: netleash)?.executableURL,
      FileManager.default.isExecutableFile(atPath: executable.path) else {
    fail(L("Install Netleash in Applications before using this shortcut."))
}
let configuration = NSWorkspace.OpenConfiguration()
configuration.arguments = ["--background"]
configuration.activates = false
NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: netleash, configuration: configuration) { _, error in
    DispatchQueue.main.async {
        if let error { fail(error.localizedDescription) }
        exit(0)
    }
}
app.run()
