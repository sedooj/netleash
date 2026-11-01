// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Netleash contributors
// Netleash — the single app of the project: launcher for the protected app, menu bar status
// icon, leak test, log viewer and emergency rollback. It makes no network decisions itself: it only reads the
// daemon's status file and starts the protected app through the setuid helper.
//
//   Netleash              open the protected app (and show the icon if it is not shown yet)
//   Netleash --background only the icon (this is how it starts at login)

import AppKit

let installName = "netleash"
let statusPath = "/var/run/\(installName)/status.json"
let libexec = "/usr/local/libexec/\(installName)"
let helperPath = "\(libexec)/netleash-exec"
let cliPath = "/usr/local/bin/netleash"
let logPath = "/var/log/\(installName).log"
let protectedBinary = "/Applications/Claude.app/Contents/MacOS/Claude"
let protectedBundleID = "com.anthropic.claudefordesktop"
let agentLabel = "org.netleash.app"
let agentPath = NSHomeDirectory() + "/Library/LaunchAgents/\(agentLabel).plist"
let launchLog = NSHomeDirectory() + "/Library/Logs/Netleash-launch.log"

// MARK: - Protection state

enum State {
    case up(String)      // VPN is up, protection armed
    case down            // VPN is down, network of the protected app is blocked
    case broken(String)  // daemon not running / pf not armed

    var symbol: String {
        switch self {
        case .up: return "lock.shield.fill"
        case .down: return "lock.slash.fill"
        case .broken: return "exclamationmark.triangle.fill"
        }
    }
    var color: NSColor {
        switch self {
        case .up: return .systemGreen
        case .down: return .systemRed
        case .broken: return .systemOrange
        }
    }
    var title: String {
        switch self {
        case .up(let i): return "VPN connected (\(i)) — network allowed"
        case .down: return "VPN disconnected — network blocked"
        case .broken(let why): return "Protection is not working: \(why)"
        }
    }
}

func readState() -> State {
    guard let data = FileManager.default.contents(atPath: statusPath),
          let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let ts = d["ts"] as? Double else { return .broken("daemon is not running") }
    if Date().timeIntervalSince1970 - ts > 5 { return .broken("daemon is not responding") }
    if (d["armed"] as? Bool) != true { return .broken((d["note"] as? String) ?? "pf is not armed") }
    return (d["vpnUp"] as? Bool) == true ? .up((d["iface"] as? String) ?? "?") : .down
}

// MARK: - Helpers

/// Runs a command as root through the standard macOS administrator prompt.
func runAsAdmin(_ cmd: String) -> String {
    var err: NSDictionary?
    let r = NSAppleScript(source: "do shell script \"\(cmd)\" with administrator privileges")?.executeAndReturnError(&err)
    if let e = err { return "Error: \(e[NSAppleScript.errorMessage] ?? e)" }
    return r?.stringValue ?? "Done"
}

func alert(_ title: String, _ text: String = "", style: NSAlert.Style = .informational) {
    let a = NSAlert()
    a.messageText = title
    a.informativeText = text
    a.alertStyle = style
    NSApp.activate(ignoringOtherApps: true)
    a.runModal()
}

func launchctl(_ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
}

// MARK: - App

final class App: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let loginItem = NSMenuItem(title: "Start at login", action: nil, keyEquivalent: "")
    let testItem = NSMenuItem(title: "Run leak test…", action: nil, keyEquivalent: "")
    var last = ""
    let background = CommandLine.arguments.contains("--background")

    func applicationDidFinishLaunching(_ n: Notification) {
        let menu = NSMenu()
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        add(menu, "Open Claude", #selector(openProtectedApp))
        menu.addItem(.separator())
        testItem.action = #selector(testLeaks); testItem.target = self; menu.addItem(testItem)
        add(menu, "Show log", #selector(showLog))
        menu.addItem(.separator())
        loginItem.action = #selector(toggleLogin); loginItem.target = self; menu.addItem(loginItem)
        menu.addItem(.separator())
        add(menu, "Emergency rollback (remove protection)…", #selector(panic))
        add(menu, "Restore protection", #selector(resume))
        menu.addItem(.separator())
        add(menu, "Quit", #selector(quit), key: "q")
        menu.delegate = self
        item.menu = menu
        refresh()
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
        if !background { openProtectedApp() }
    }

    /// The app was opened again (Dock, Spotlight, double click) while the icon is already running.
    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openProtectedApp()
        return false
    }

    func add(_ menu: NSMenu, _ title: String, _ sel: Selector, key: String = "") {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        menu.addItem(i)
    }

    func refresh() {
        let s = readState()
        header.title = s.title
        item.button?.toolTip = s.title
        let key = s.symbol + s.title
        guard key != last else { return }
        last = key
        let img = NSImage(systemSymbolName: s.symbol, accessibilityDescription: s.title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [s.color]))
        img?.isTemplate = false
        item.button?.image = img
    }

    // MARK: Actions

    /// Starts the protected app under protection (or brings an already running one to the front).
    @objc func openProtectedApp() {
        if let r = NSRunningApplication.runningApplications(withBundleIdentifier: protectedBundleID).first {
            r.activate()
            return
        }
        FileManager.default.createFile(atPath: launchLog, contents: nil)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: helperPath)
        p.arguments = [protectedBinary]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle(forWritingAtPath: launchLog) ?? FileHandle.nullDevice
        do { try p.run() } catch {
            alert("Could not start the app", "\(error)\n\nCheck the installation: netleash status", style: .critical)
            return
        }
        // The helper refuses to start when protection is not armed: say so instead of failing silently.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard !p.isRunning, p.terminationStatus != 0 else { return }
            let msg = (try? String(contentsOfFile: launchLog, encoding: .utf8)) ?? ""
            alert("Not started: protection is not active", msg.isEmpty ? "Check: netleash status" : msg, style: .critical)
        }
    }

    @objc func testLeaks() {
        testItem.title = "Testing…"
        testItem.isEnabled = false
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: cliPath)
            p.arguments = ["test"]
            let out = Pipe(); p.standardOutput = out; p.standardError = out
            try? p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            DispatchQueue.main.async {
                self.testItem.title = "Run leak test…"
                self.testItem.isEnabled = true
                alert(p.terminationStatus == 0 ? "No leaks found" : "Leak test failed",
                      String(decoding: data, as: UTF8.self), style: p.terminationStatus == 0 ? .informational : .critical)
            }
        }
    }

    @objc func showLog() { NSWorkspace.shared.open(URL(fileURLWithPath: logPath)) }
    @objc func quit() { NSApp.terminate(nil) }

    @objc func panic() {
        let a = NSAlert()
        a.messageText = "Remove all protection?"
        a.informativeText = "The daemon will be stopped and the pf rules removed. The protected app will be able to use the network without the VPN until you choose “Restore protection”."
        a.alertStyle = .warning
        a.addButton(withTitle: "Cancel")
        a.addButton(withTitle: "Roll back")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertSecondButtonReturn else { return }
        alert(runAsAdmin("\(libexec)/panic.sh"))
    }

    @objc func resume() { alert(runAsAdmin("\(libexec)/resume.sh")) }

    // MARK: Start at login

    var loginEnabled: Bool { FileManager.default.fileExists(atPath: agentPath) }

    @objc func toggleLogin() {
        let uid = String(getuid())
        if loginEnabled {
            launchctl(["bootout", "gui/\(uid)/\(agentLabel)"])
            try? FileManager.default.removeItem(atPath: agentPath)
        } else {
            let exe = Bundle.main.executablePath ?? "/Applications/Netleash.app/Contents/MacOS/Netleash"
            let plist: [String: Any] = ["Label": agentLabel, "ProgramArguments": [exe, "--background"], "RunAtLoad": true]
            try? FileManager.default.createDirectory(atPath: (agentPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            (plist as NSDictionary).write(toFile: agentPath, atomically: true)
            // Not started now: the app is already running, the agent takes effect at the next login.
        }
    }
}

extension App: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) { loginItem.state = loginEnabled ? .on : .off }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
