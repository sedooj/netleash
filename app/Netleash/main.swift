// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Netleash contributors
// Netleash — the single app of the project: launcher for the protected app, menu bar status
// icon, leak test, log viewer and emergency rollback. It makes no network decisions itself: it only reads the
// daemon's status file and starts the protected app through the setuid helper.
//
//   Netleash              show application settings (and the menu bar icon)
//   Netleash --background only the icon (this is how it starts at login)

import AppKit
import UserNotifications
import UniformTypeIdentifiers

let installName = "netleash"
let statusPath = "/var/run/\(installName)/status.json"
let libexec = "/usr/local/libexec/\(installName)"
let helperPath = "\(libexec)/netleash-exec"
let cliPath = "/usr/local/bin/netleash"
let logPath = "/var/log/\(installName).log"
let configPath = "/usr/local/etc/\(installName)/config.json"
let agentLabel = "org.netleash.app"
let agentPath = NSHomeDirectory() + "/Library/LaunchAgents/\(agentLabel).plist"
let updateDailyKey = "updateCheckDaily"
let lastCheckKey = "lastUpdateCheck"
let notifiedKey = "notifiedUpdateVersion"
let launchLog = NSHomeDirectory() + "/Library/Logs/Netleash-launch.log"

/// Localized string: the English text is the key (see Resources/ru.lproj/Localizable.strings).
func L(_ key: String, _ args: CVarArg...) -> String {
    let f = NSLocalizedString(key, comment: "")
    return args.isEmpty ? f : String(format: f, arguments: args)
}

// MARK: - Original application bundles

struct ProtectedApplication: Equatable {
    let path: String
    let enabled: Bool
    var url: URL { URL(fileURLWithPath: path) }
    var bundle: Bundle? { Bundle(url: url) }
    var name: String { (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
        ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
        ?? url.deletingPathExtension().lastPathComponent }
    var installed: Bool { bundle?.executableURL.map { FileManager.default.isExecutableFile(atPath: $0.path) } ?? false }
    var running: Bool { NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.resolvingSymlinksInPath().path == path } }
    var status: String {
        if !installed { return L("Not installed") }
        if !enabled { return L("Protection off") }
        switch readState() {
        case .up: return running ? L("Running · VPN connected") : L("VPN connected")
        case .down: return running ? L("Running · network blocked") : L("VPN disconnected — network blocked")
        case .broken: return L("Protection unavailable")
        }
    }
}

func protectedApplications() -> [ProtectedApplication] {
    let data = FileManager.default.contents(atPath: configPath)
    let doc = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    if let apps = doc["protectedApps"] as? [[String: Any]] {
        return apps.compactMap { a in
            guard let path = a["path"] as? String else { return nil }
            return ProtectedApplication(path: path, enabled: a["enabled"] as? Bool ?? true)
        }
    }
    return [ProtectedApplication(path: doc["protectedAppPath"] as? String ?? "/Applications/Claude.app", enabled: true)]
}

func daemonHasApplied(_ app: ProtectedApplication) -> Bool {
    guard let data = FileManager.default.contents(atPath: statusPath),
          let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let apps = d["protectedApps"] as? [[String: Any]] else { return false }
    return apps.contains { $0["path"] as? String == app.path && $0["enabled"] as? Bool == true }
}

func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

var installationReady: Bool {
    [cliPath, helperPath, "\(libexec)/netleash", "\(libexec)/netleash-spawn"].allSatisfy { FileManager.default.isExecutableFile(atPath: $0) }
        && FileManager.default.fileExists(atPath: configPath)
}

// MARK: - Protection state

enum State {
    case up(String)      // VPN is up, protection armed
    case down            // VPN is down, network of the protected app is blocked
    case broken(String)  // daemon not running / pf not armed

    var symbol: String {   // SF Symbol, used only as a fallback if the bundled glyph is missing
        switch self {
        case .up: return "lock.shield.fill"
        case .down: return "lock.slash.fill"
        case .broken: return "exclamationmark.triangle.fill"
        }
    }
    var glyph: String {    // bundled menu bar glyph (Resources/menubar-<glyph>@2x.png, drawn at 18 pt)
        switch self {
        case .up: return "up"
        case .down: return "down"
        case .broken: return "warn"
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
        case .up(let i): return L("VPN connected (%@) — network allowed", i)
        case .down: return L("VPN disconnected — network blocked")
        case .broken(let why): return L("Protection is not working: %@", why)
        }
    }
}

/// Events published by the daemon in the status file (VPN down/up, unprotected launch closed).
var lastEventSeq: Int64?

func handleEvents() {
    guard let data = FileManager.default.contents(atPath: statusPath),
          let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let ev = d["event"] as? [String: Any], let seq = (ev["seq"] as? NSNumber)?.int64Value else { return }
    guard let last = lastEventSeq else { lastEventSeq = seq; return }   // first read: do not replay old events
    guard seq > last else { return }
    lastEventSeq = seq
    var title = ev["title"] as? String ?? "Netleash"
    var text = ev["text"] as? String ?? ""
    switch ev["kind"] as? String {   // known kinds are shown in the user's language
    case "vpn_down": title = L("VPN disconnected"); text = L("Network access is blocked.")
    case "vpn_up": title = L("VPN connected"); text = L("Network access restored through the VPN.")
    case "app_closed": title = L("App closed"); text = L("Start it only through Netleash.")
    default: break
    }
    Notifier.shared.post(title, text)
}

func readState() -> State {
    guard let data = FileManager.default.contents(atPath: statusPath),
          let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let ts = d["ts"] as? Double else { return .broken(L("daemon is not running")) }
    if Date().timeIntervalSince1970 - ts > 5 { return .broken(L("daemon is not responding")) }
    if (d["armed"] as? Bool) != true { return .broken((d["note"] as? String) ?? L("pf is not armed")) }
    return (d["vpnUp"] as? Bool) == true ? .up((d["iface"] as? String) ?? "?") : .down
}

// MARK: - Helpers

enum AdminResult {
    case success(String)
    case cancelled
    case failure(String)
}

/// Administrator cancellation is an ordinary outcome, never a failed operation or a successful install.
func runAsAdmin(_ cmd: String) -> AdminResult {
    var error: NSDictionary?
    let escaped = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    guard let script = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges") else {
        return .failure(L("Could not request administrator access."))
    }
    let result = script.executeAndReturnError(&error)
    if let error {
        if (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue == -128 { return .cancelled }
        return .failure("\(error[NSAppleScript.errorMessage] ?? error)")
    }
    return .success(result.stringValue ?? "")
}

func startInstaller(_ path: String) -> AdminResult {
    let runner = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("netleash")
    guard FileManager.default.isExecutableFile(atPath: runner.path) else {
        return .failure(L("This copy is incomplete. Open Netleash from a complete release or rebuild the app."))
    }
    return runAsAdmin([runner.path, "installer-start", path].map(shellQuote).joined(separator: " "))
}

// MARK: - Settings stored for the app and the command line

let languageKey = "AppleLanguages"
let bannersKey = "bannersEnabled"
let supportDir = NSHomeDirectory() + "/Library/Application Support/Netleash"

/// "system", "en" or "ru". The command-line tool reads the same choice from a file next to the app's data.
var chosenLanguage: String {
    get {
        let langs = UserDefaults.standard.array(forKey: languageKey) as? [String]
        return langs?.first.map { $0.hasPrefix("ru") ? "ru" : "en" } ?? "system"
    }
    set {
        if newValue == "system" { UserDefaults.standard.removeObject(forKey: languageKey) }
        else { UserDefaults.standard.set([newValue], forKey: languageKey) }
        try? FileManager.default.createDirectory(atPath: supportDir, withIntermediateDirectories: true)
        let f = supportDir + "/language"
        if newValue == "system" { try? FileManager.default.removeItem(atPath: f) }
        else { try? newValue.write(toFile: f, atomically: true, encoding: .utf8) }
    }
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
    if p.isRunning { p.waitUntilExit() }
}

// MARK: - Toast: Netleash's own notification banner (used when macOS does not allow notifications for the app)

final class Toast {
    static var panel: NSPanel?
    static var generation = 0

    static func content(_ title: String, _ body: String, _ w: CGFloat = 360, _ h: CGFloat = 76) -> NSVisualEffectView {
        let fx = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
            fx.material = .hudWindow
            fx.state = .active
            fx.wantsLayer = true
            fx.layer?.cornerRadius = 16
            fx.layer?.masksToBounds = true

            let icon = NSImageView(frame: NSRect(x: 14, y: (h - 44) / 2, width: 44, height: 44))
            icon.image = Bundle.main.path(forResource: "icon", ofType: "icns").flatMap { NSImage(contentsOfFile: $0) } ?? NSApp.applicationIconImage
            let t = NSTextField(labelWithString: title)
            t.font = .boldSystemFont(ofSize: 13)
            t.frame = NSRect(x: 70, y: h - 34, width: w - 84, height: 18)
            let b = NSTextField(wrappingLabelWithString: body)
            b.font = .systemFont(ofSize: 12)
            b.textColor = .secondaryLabelColor
            b.maximumNumberOfLines = 2
            b.frame = NSRect(x: 70, y: 10, width: w - 84, height: h - 46)
            [icon, t, b].forEach { fx.addSubview($0) }
        return fx
    }

    static func show(_ title: String, _ body: String, seconds: Double = 7) {
        DispatchQueue.main.async {
            panel?.orderOut(nil)
            let w: CGFloat = 360, h: CGFloat = 76
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.level = .statusBar
            p.hasShadow = true
            p.isOpaque = false
            p.backgroundColor = .clear
            p.isReleasedWhenClosed = false
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

            let fx = content(title, body, w, h)
            p.contentView = fx

            if let scr = NSScreen.main {
                let f = scr.visibleFrame
                p.setFrameOrigin(NSPoint(x: f.maxX - w - 12, y: f.maxY - h - 12))
            }
            p.alphaValue = 0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.2; p.animator().alphaValue = 1 }
            panel = p
            generation += 1
            let mine = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                guard generation == mine, let cur = panel else { return }
                NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; cur.animator().alphaValue = 0 },
                                                     completionHandler: { if generation == mine { cur.orderOut(nil) } })
            }
        }
    }
}

// MARK: - Notifications (shown under the Netleash name and icon)

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    /// UNUserNotificationCenter needs a real app bundle; a bare binary falls back to AppleScript.
    private var usable: Bool { Bundle.main.bundlePath.hasSuffix(".app") }

    /// Diagnostics (~/Library/Logs/Netleash.log): why a notification did or did not appear.
    func log(_ s: String) {
        let path = NSHomeDirectory() + "/Library/Logs/Netleash.log"
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(s)\n"
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile() }
        else { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
    }

    func setup() {
        guard usable else { log("not running from an app bundle: notifications use Netleash banners"); return }
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.requestAuthorization(options: [.alert, .sound]) { granted, err in
            self.log("authorization granted=\(granted) error=\(err.map { "\($0)" } ?? "none")")
        }
        c.getNotificationSettings { s in
            self.log("settings: authorizationStatus=\(s.authorizationStatus.rawValue) (2 = authorized) alert=\(s.alertSetting.rawValue)")
        }
    }

    /// Used when macOS does not allow notifications for Netleash (typical for ad-hoc signed apps): Netleash shows its own banner.
    private func fallback(_ title: String, _ body: String) { Toast.show(title, body) }

    func post(_ title: String, _ body: String) {
        if (UserDefaults.standard.object(forKey: bannersKey) as? Bool) == false { return }   // switched off in Settings
        guard usable else { fallback(title, body); return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { s in
            guard s.authorizationStatus == .authorized || s.authorizationStatus == .provisional else {
                self.log("macOS notifications not allowed (status \(s.authorizationStatus.rawValue)); showing a Netleash banner for: \(title)")
                self.fallback(title, body)
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { err in
                if let err = err { self.log("posting failed: \(err); using the fallback"); self.fallback(title, body) }
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}

/// Starts a program that macOS treats as its OWN "responsible process". With a plain Process the protected app would be
/// attributed to Netleash, so privacy prompts (Downloads, Documents, Desktop, …) would name Netleash instead of the app,
/// and permissions already granted to the app (screen recording, accessibility, …) would not apply. Uses the same
/// call that terminals and launchers use to disclaim responsibility for what they spawn.
func spawnDisclaimed(_ path: String, _ args: [String]) -> pid_t? {
    FileManager.default.createFile(atPath: launchLog, contents: nil)
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
    if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") {   // RTLD_DEFAULT
        _ = unsafeBitCast(sym, to: Disclaim.self)(&attr, 1)
    }
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 2, launchLog, O_WRONLY | O_APPEND, 0o600)

    let argv: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    var pid: pid_t = 0
    let rc = posix_spawn(&pid, path, &actions, &attr, argv, environ)
    return rc == 0 ? pid : nil
}

// MARK: - App

final class App: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let testItem = NSMenuItem(title: L("Test network protection…"), action: nil, keyEquivalent: "")
    let updateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")   // visible only when an update is known
    let appsMenu = NSMenu()
    var settings: SettingsWindow?
    var applications: ApplicationsWindow?
    var logWindow: LogWindow?
    var testingProtection = false
    var installingProtection = false
    var installationTimer: Timer?
    var installationNotice: String?
    var availableUpdate: String?   // set when a newer release is known
    var last = ""
    let background = CommandLine.arguments.contains("--background")

    func applicationDidFinishLaunching(_ n: Notification) {
        if installationReady { Notifier.shared.setup() }
        let menu = NSMenu()
        menu.autoenablesItems = false
        appsMenu.autoenablesItems = false
        header.isEnabled = false
        menu.addItem(header)
        let ver = NSMenuItem(title: "Netleash \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?")", action: nil, keyEquivalent: "")
        ver.isEnabled = false
        menu.addItem(ver)
        menu.addItem(.separator())
        updateItem.action = #selector(updateFromMenu); updateItem.target = self; updateItem.isHidden = true
        menu.addItem(updateItem)
        let appsItem = NSMenuItem(title: L("Applications"), action: nil, keyEquivalent: "")
        appsItem.submenu = appsMenu
        menu.addItem(appsItem)
        rebuildApplicationsMenu()
        menu.addItem(.separator())
        testItem.action = #selector(testLeaks); testItem.target = self; menu.addItem(testItem)
        add(menu, L("Show log"), #selector(showLog))
        add(menu, L("Settings…"), #selector(openSettings), key: ",")
        menu.addItem(.separator())
        add(menu, L("Emergency rollback (remove protection)…"), #selector(panic))
        add(menu, L("Restore protection"), #selector(resume))
        menu.addItem(.separator())
        add(menu, L("Quit"), #selector(quit), key: "q")
        menu.delegate = self
        item.menu = menu
        refresh()
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.dailyCheckIfDue() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.dailyCheckIfDue() }
        if !background {
            if CommandLine.arguments.contains("--settings") { openSettings() } else { openApplications() }
        }
    }

    /// The app was opened again (Dock, Spotlight, double click) while the icon is already running.
    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openApplications()
        return false
    }

    /// Desktop launchers send a bundle URL through LaunchServices, including when Netleash is already running.
    func application(_ application: NSApplication, open urls: [URL]) {
        var opened = Set<String>()
        for url in urls where url.isFileURL && url.pathExtension == "app" {
            let path = url.resolvingSymlinksInPath().path
            if opened.insert(path).inserted { openProtectedApp(path) }
        }
    }

    func add(_ menu: NSMenu, _ title: String, _ sel: Selector, key: String = "") {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        menu.addItem(i)
    }

    func refresh() {
        handleEvents()
        testItem.isEnabled = canTestProtection
        settings?.refreshAvailability()
        let s = readState()
        header.title = installationReady ? s.title : L("Netleash is not installed")
        item.button?.toolTip = header.title
        let key = s.symbol + s.title
        guard key != last else { return }
        last = key
        var img: NSImage?
        if let path = Bundle.main.path(forResource: "menubar-\(s.glyph)@2x", ofType: "png"), let g = NSImage(contentsOfFile: path) {
            g.size = NSSize(width: 18, height: 18)   // the file is 36 px: 2x of 18 pt
            img = g
        } else {
            img = NSImage(systemSymbolName: s.symbol, accessibilityDescription: s.title)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [s.color]))
        }
        img?.isTemplate = false
        item.button?.image = img
    }

    // MARK: Actions

    /// Starts the protected app under protection (or brings an already running one to the front).
    func rebuildApplicationsMenu() {
        appsMenu.removeAllItems()
        let configured = FileManager.default.fileExists(atPath: configPath) ? protectedApplications() : []
        for a in configured where a.enabled {
            let row = NSMenuItem(title: L("Open %@", a.name), action: #selector(openConfiguredApp(_:)), keyEquivalent: "")
            row.target = self
            row.representedObject = a.path
            row.isEnabled = canManageApplications && a.installed
            row.toolTip = a.status
            let icon = NSWorkspace.shared.icon(forFile: a.path)
            icon.size = NSSize(width: 16, height: 16)
            row.image = icon
            appsMenu.addItem(row)
        }
        if appsMenu.items.isEmpty {
            let row = NSMenuItem(title: L("No protected applications"), action: nil, keyEquivalent: "")
            row.isEnabled = false
            appsMenu.addItem(row)
        }
        appsMenu.addItem(.separator())
        add(appsMenu, L("Manage applications…"), #selector(openApplications))
    }

    @objc func openConfiguredApp(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        openProtectedApp(path)
    }

    func openProtectedApp(_ path: String) {
        guard requireInstallation() else { return }
        guard let a = protectedApplications().first(where: { $0.path == path }) else {
            alert(L("Could not start the app"), L("Add this application to Netleash before using its shortcut."), style: .warning)
            return
        }
        guard a.enabled else {
            alert(L("Protection is off"), L("Enable protection for %@ in Netleash before launching it from this shortcut.", a.name))
            return
        }
        guard a.installed, let binary = a.bundle?.executableURL?.path else {
            alert(L("Could not start the app"), L("Select an installed app in the applications window."), style: .critical)
            return
        }
        guard daemonHasApplied(a) else {
            alert(L("Not started: protection is not active"), L("Check: netleash status"), style: .critical)
            return
        }
        if case .broken = readState() {
            alert(L("Not started: protection is not active"), L("Check: netleash status"), style: .critical)
            return
        }
        launchProtectedApp(a, binary)
    }

    private func launchProtectedApp(_ a: ProtectedApplication, _ binary: String) {
        if let r = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.resolvingSymlinksInPath().path == a.path }) {
            guard processIsConfined(r.processIdentifier) else {
                alert(L("Close the app first"), L("Save your work and quit %@ before enabling protection. Then launch it from Netleash.", a.name))
                return
            }
            r.activate()
            return
        }
        guard let pid = spawnDisclaimed(helperPath, ["--disclaim", binary]) else {
            alert(L("Could not start the app"), L("Check the installation: netleash status"), style: .critical)
            return
        }
        // The helper refuses to start when protection is not armed: say so instead of failing silently.
        let started = Date()
        DispatchQueue.global().async {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            let failedFast = Date().timeIntervalSince(started) < 5
            let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            guard failedFast, code != 0 else { return }
            DispatchQueue.main.async {
                let msg = (try? String(contentsOfFile: launchLog, encoding: .utf8)) ?? ""
                alert(L("Not started: protection is not active"), msg.isEmpty ? L("Check: netleash status") : msg, style: .critical)
            }
        }
    }

    var canManageApplications: Bool {
        guard installationReady, !installingProtection else { return false }
        if case .broken = readState() { return false }
        return true
    }

    var canTestProtection: Bool {
        guard installationReady, !testingProtection else { return false }
        if case .broken = readState() { return false }
        return true
    }

    @objc func testLeaks() {
        guard requireInstallation() else { return }
        guard !testingProtection else { return }
        guard canTestProtection else {
            alert(L("Protection is not ready"), L("Start protection before running the network test."))
            return
        }
        testingProtection = true
        testItem.title = L("Testing…")
        refresh()
        DispatchQueue.global().async {
            let result = runCommand(cliPath, ["test"], timeout: 45)
            DispatchQueue.main.async {
                self.testingProtection = false
                self.testItem.title = L("Test network protection…")
                self.refresh()
                if result.timedOut {
                    alert(L("Network test timed out"), L("The test was stopped after 45 seconds. You can try again or open the log."), style: .warning)
                } else if result.error != nil {
                    alert(L("Could not run the network test"), L("Check the Netleash installation and try again."), style: .warning)
                } else {
                    let title = result.exitCode == 0 ? L("Network test completed") : (result.exitCode == 2 ? L("Network test incomplete") : L("Network test failed"))
                    alert(title,
                          result.output.isEmpty ? L("The command returned no result. Open the log for details.") : result.output,
                          style: result.exitCode == 0 ? .informational : .warning)
                }
            }
        }
    }

    @objc func openNotificationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
    }
    @objc func showLog() {
        if logWindow == nil { logWindow = LogWindow() }
        logWindow?.show()
    }
    @objc func quit() { NSApp.terminate(nil) }

    @objc func panic() {
        guard requireInstallation() else { return }
        let a = NSAlert()
        a.messageText = L("Remove all protection?")
        a.informativeText = L("The daemon will be stopped and the pf rules removed. Protected apps will be able to use the network without the VPN until you choose “Restore protection”.")
        a.alertStyle = .warning
        a.addButton(withTitle: L("Cancel"))
        a.addButton(withTitle: L("Roll back"))
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertSecondButtonReturn else { return }
        administrativeAction("panic.sh")
    }

    @objc func resume() { if requireInstallation() { administrativeAction("resume.sh") } }

    func administrativeAction(_ script: String) {
        if case .failure(let message) = runAsAdmin(shellQuote("\(libexec)/\(script)")) {
            alert(L("Could not change protection"), message, style: .warning)
        }
        refresh()
        applications?.refresh()
    }

    // MARK: Updates

    /// Runs `netleash update …` (through the VPN unless the user asked otherwise) and returns the parsed JSON.
    func runUpdate(_ args: [String], completion: @escaping ([String: Any]) -> Void) {
        guard installationReady else {
            completion(["error": L("Install Netleash before checking for updates.")])
            return
        }
        DispatchQueue.global().async {
            let command = runCommand(cliPath, ["update", "--json"] + args, timeout: 120)
            var result: [String: Any]
            if command.timedOut {
                result = ["error": L("The update request timed out. Try again later.")]
            } else if command.error != nil {
                result = ["error": L("Could not start the update check. Check the Netleash installation.")]
            } else if let data = command.output.data(using: .utf8),
                      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                result = json
            } else {
                result = ["error": L("The update command returned no readable result.")]
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    @objc func openApplications() {
        if applications == nil { applications = ApplicationsWindow(app: self) }
        applications?.show()
    }

    @discardableResult func requireInstallation() -> Bool {
        if installingProtection { openApplications(); return false }
        if installationReady { return true }
        openApplications()
        return false
    }

    @objc func installNetleash() {
        guard !installingProtection else { return }
        let installer: URL
        do { installer = try prepareInstaller() }
        catch { alert(L("Installer not found"), error.localizedDescription, style: .warning); return }
        // Updating can close configured apps. The first install starts with an empty app list.
        if FileManager.default.fileExists(atPath: configPath), protectedApplications().contains(where: { $0.enabled }) {
            let a = NSAlert()
            a.messageText = L("Install Netleash?")
            a.informativeText = L("This installs the background protection service and asks for your administrator password. Save your work in protected apps before updating. Netleash will reopen after installation.")
            a.addButton(withTitle: L("Install")); a.addButton(withTitle: L("Cancel"))
            guard a.runModal() == .alertFirstButtonReturn else { removePreparedInstaller(installer); return }
        }
        installingProtection = true
        applications?.refresh()
        switch startInstaller(installer.path) {
        case .success(let job): trackInstallation(job, installer: installer)
        case .cancelled: installingProtection = false; removePreparedInstaller(installer)
        case .failure(let message):
            installingProtection = false
            removePreparedInstaller(installer)
            alert(L("Installation could not start"), message, style: .warning)
        }
        applications?.refresh()
    }

    func trackInstallation(_ job: String, installer: URL? = nil) {
        guard let pid = Int32(job.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else {
            installingProtection = false
            installationNotice = L("Installation did not complete. Open the log for details.")
            return
        }
        installingProtection = true
        installationNotice = nil
        installationTimer?.invalidate()
        installationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if kill(pid, 0) == 0 || errno == EPERM { return }
            timer.invalidate()
            self.installingProtection = false
            if let installer { removePreparedInstaller(installer) }
            if !self.canManageApplications {
                self.installationNotice = L("Installation did not complete. Open the log for details.")
                self.showLog()
                self.logWindow?.sources.selectItem(at: 3)
                self.logWindow?.refresh()
            }
            self.applications?.refresh()
        }
    }

    @objc func openSettings() {
        if settings == nil { settings = SettingsWindow(app: self) }
        settings?.show()
    }

    /// The menu entry that appears when an update is known.
    @objc func updateFromMenu() { checkForUpdates(userInitiated: true) }

    /// Checks for an update; `done` receives (current, latest, url) when one is available, or an error text.
    func checkForUpdates(userInitiated: Bool, done: ((String) -> Void)? = nil) {
        runUpdate(["--check"]) { r in
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
            if let err = r["error"] as? String, !err.isEmpty {
                done?(L("Could not check for updates") + ": " + err)
                if userInitiated { alert(L("Could not check for updates"), err, style: .warning) }
                return
            }
            let current = r["current"] as? String ?? "?"
            guard (r["update"] as? Bool) == true, let latest = r["latest"] as? String else {
                self.setAvailableUpdate(nil)
                done?(L("Netleash is up to date") + " (" + L("Version %@.", current) + ")")
                if userInitiated { alert(L("Netleash is up to date"), L("Version %@.", current)) }
                return
            }
            self.setAvailableUpdate(latest)
            done?(L("Update available: %@…", latest))
            if userInitiated {
                self.offerUpdate(current: current, latest: latest, url: r["url"] as? String)
            } else if UserDefaults.standard.string(forKey: notifiedKey) != latest {
                UserDefaults.standard.set(latest, forKey: notifiedKey)
                Notifier.shared.post(L("Netleash update"), L("Version %@ is available. Open the Netleash menu to update.", latest))
            }
        }
    }

    func setAvailableUpdate(_ v: String?) {
        availableUpdate = v
        updateItem.isHidden = (v == nil)
        if let v = v { updateItem.title = L("Update available: %@…", v) }
    }

    func offerUpdate(current: String, latest: String, url: String?) {
        let a = NSAlert()
        a.messageText = L("Netleash %@ is available", latest)
        a.informativeText = L("You have %@. The update is downloaded through the VPN and its SHA-256 checksum is verified; you are asked for your administrator password to install it. Protected apps are closed during the update and reopened afterwards (save your work first), and this menu bar app restarts.", current)
        a.addButton(withTitle: L("Update"))
        a.addButton(withTitle: L("Release notes"))
        a.addButton(withTitle: L("Later"))
        NSApp.activate(ignoringOtherApps: true)
        switch a.runModal() {
        case .alertFirstButtonReturn: performUpdate()
        case .alertSecondButtonReturn: if let u = url, let link = URL(string: u) { NSWorkspace.shared.open(link) }
        default: break
        }
    }

    func performUpdate() {
        updateItem.title = L("Downloading update…"); updateItem.isHidden = false; updateItem.isEnabled = false
        runUpdate(["--download-only"]) { r in
            self.updateItem.isEnabled = true
            guard let installer = r["installer"] as? String else {
                self.setAvailableUpdate(self.availableUpdate)
                alert(L("Update failed"), (r["error"] as? String) ?? L("unknown error"), style: .critical)
                return
            }
            // The installer closes protected apps and restarts this app, so it runs detached and logs to a file.
            switch startInstaller(installer) {
            case .success(let job):
                self.trackInstallation(job)
                alert(L("Update started"), L("Protected apps will close and open again, and Netleash will restart in a few seconds. Progress: /var/log/netleash-install.log"))
            case .cancelled:
                self.setAvailableUpdate(self.availableUpdate)
            case .failure(let message):
                self.setAvailableUpdate(self.availableUpdate)
                alert(L("Update failed"), message, style: .warning)
            }
        }
    }

    func setDaily(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: updateDailyKey)
        if on && installationReady { checkForUpdates(userInitiated: false) }
    }

    /// Opt-in: at most one silent check per day. The request goes through the VPN; if the VPN is down it is skipped.
    func dailyCheckIfDue() {
        let d = UserDefaults.standard
        guard d.bool(forKey: updateDailyKey) else { return }
        if Date().timeIntervalSince1970 - d.double(forKey: lastCheckKey) < 86400 { return }
        guard case .up = readState() else { return }
        checkForUpdates(userInitiated: false)
    }

    // MARK: Start at login

    var loginEnabled: Bool { FileManager.default.fileExists(atPath: agentPath) }

    func setLogin(_ on: Bool) throws {
        let uid = String(getuid())
        if !on {
            if FileManager.default.fileExists(atPath: agentPath) { try FileManager.default.removeItem(atPath: agentPath) }
            DispatchQueue.global().async { _ = runCommand("/bin/launchctl", ["bootout", "gui/\(uid)/\(agentLabel)"], timeout: 3) }
        } else {
            // Started through LaunchServices ("open"): macOS only registers an app for notifications when it is launched that way.
            let plist: [String: Any] = ["Label": agentLabel,
                                        "ProgramArguments": ["/usr/bin/open", "-g", "-a", "/Applications/Netleash.app", "--args", "--background"],
                                        "RunAtLoad": true]
            try FileManager.default.createDirectory(atPath: (agentPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: URL(fileURLWithPath: agentPath), options: .atomic)
            // Not started now: the app is already running, the agent takes effect at the next login.
        }
    }
}

func processIsConfined(_ pid: pid_t) -> Bool {
    guard let data = FileManager.default.contents(atPath: statusPath),
          let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let gid = d["gid"] as? Int, gid > 0 else { return false }
    let result = runCommand("/bin/ps", ["-o", "gid=", "-p", String(pid)], timeout: 2)
    return result.exitCode == 0 && Int(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) == gid
}

extension App: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) { rebuildApplicationsMenu() }
}

if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--check-installer" {
    // Validate the self-contained first-run payload without requesting privileges or installing anything.
    do {
        let installer = try prepareInstaller()
        let folder = installer.deletingLastPathComponent()
        let complete = FileManager.default.fileExists(atPath: folder.appendingPathComponent("Netleash.app/Contents/Info.plist").path)
        do { try checkInstallerTransport(installer) }
        catch { removePreparedInstaller(installer); throw error }
        removePreparedInstaller(installer)
        guard complete else {
            throw CocoaError(.fileNoSuchFile)
        }
        print("OK: payload staged; detached installer executed through AppleScript; stdout/stderr captured; nothing installed")
        exit(0)
    } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
}
if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--create-shortcut" {
    // Scriptable shortcut creation; protection is checked by Netleash when the shortcut is opened.
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    do {
        try createShortcut(for: ProtectedApplication(path: CommandLine.arguments[2], enabled: true),
                           at: URL(fileURLWithPath: CommandLine.arguments[3]))
        print(CommandLine.arguments[3])
        exit(0)
    } catch {
        if ProcessInfo.processInfo.environment["NETLEASH_DEBUG_SHORTCUT"] == "1" { fputs("\(error as NSError)\n", stderr) }
        fputs(error.localizedDescription + "\n", stderr)
        exit(1)
    }
}
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--l10n" {
    // Translation check: Netleash --l10n "Quit"   (the language follows the system, or: -AppleLanguages "(ru)")
    print(L(CommandLine.arguments[2]))
    exit(0)
}
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--render-settings" {
    // Layout check without a screen: Netleash --render-settings out.png   (add -AppleLanguages "(ru)" to check Russian)
    _ = NSApplication.shared
    let holder = App()   // SettingsWindow keeps only an unowned reference
    let w = SettingsWindow(app: holder)
    w.refresh()
    w.window.layoutIfNeeded()
    w.window.contentView?.layoutSubtreeIfNeeded()
    if let v = w.window.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    }
    withExtendedLifetime(holder) { exit(0) }
}
if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--render-toast" {
    // Layout check without a screen: Netleash --render-toast out.png "Title" "Text"
    _ = NSApplication.shared
    let v = Toast.content(CommandLine.arguments[3], CommandLine.arguments.count > 4 ? CommandLine.arguments[4] : "")
    v.layer?.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 1).cgColor
    if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    }
    exit(0)
}
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--test-toast" {
    // Manual check of the banner: Netleash.app/Contents/MacOS/Netleash --test-toast "Title" "Text"
    let a = NSApplication.shared
    a.setActivationPolicy(.accessory)
    Toast.show(CommandLine.arguments[2], CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "", seconds: 4)
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { exit(0) }
    a.run()
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
