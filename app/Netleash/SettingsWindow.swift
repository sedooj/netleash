// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Netleash contributors

import AppKit

final class SettingsWindow: NSObject, NSToolbarDelegate {
    enum Pane: String, CaseIterable {
        case general, updates, diagnostics
        var title: String {
            switch self { case .general: return L("General"); case .updates: return L("Updates"); case .diagnostics: return L("Diagnostics") }
        }
        var symbol: String {
            switch self { case .general: return "gearshape"; case .updates: return "arrow.triangle.2.circlepath"; case .diagnostics: return "stethoscope" }
        }
        var id: NSToolbarItem.Identifier { NSToolbarItem.Identifier(rawValue) }
    }
    unowned let app: App
    let window: NSWindow
    let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let bannersCheck = NSButton(checkboxWithTitle: L("Show Netleash banners and notifications"), target: nil, action: nil)
    let dailyCheck = NSButton(checkboxWithTitle: L("Check for updates daily (through the VPN)"), target: nil, action: nil)
    let loginCheck = NSButton(checkboxWithTitle: L("Start at login"), target: nil, action: nil)
    let updateStatus = secondaryText("")
    let protectionStatus = secondaryText("")
    let checkButton = NSButton(title: L("Check for updates…"), target: nil, action: nil)
    let testButton = NSButton(title: L("Test network protection…"), target: nil, action: nil)
    var pane: Pane = .general
    private var currentGrid: NSGridView?

    init(app: App) {
        self.app = app
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 340), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .preference
        let toolbar = NSToolbar(identifier: "NetleashPreferences")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        languagePopup.addItems(withTitles: [L("System default"), "English", "Русский"])
        languagePopup.target = self; languagePopup.action = #selector(languageChanged)
        bannersCheck.target = self; bannersCheck.action = #selector(bannersChanged)
        dailyCheck.target = self; dailyCheck.action = #selector(dailyChanged)
        loginCheck.target = self; loginCheck.action = #selector(loginChanged)
        checkButton.target = self; checkButton.action = #selector(checkNow)
        testButton.target = app; testButton.action = #selector(App.testLeaks)
        select(.general, animate: false)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace] + Pane.allCases.map(\.id) + [.flexibleSpace] }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Pane.allCases.map(\.id) }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let p = Pane(rawValue: identifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = p.title
        item.image = NSImage(systemSymbolName: p.symbol, accessibilityDescription: p.title)
        item.target = self; item.action = #selector(selectPane(_:))
        return item
    }
    @objc func selectPane(_ sender: NSToolbarItem) {
        if let p = Pane(rawValue: sender.itemIdentifier.rawValue) { select(p, animate: true) }
    }
    func select(_ pane: Pane, animate: Bool) {
        self.pane = pane
        window.title = pane.title
        window.toolbar?.selectedItemIdentifier = pane.id
        let rows: [[NSView]]
        func label(_ text: String) -> NSTextField { NSTextField(labelWithString: text + ":") }
        switch pane {
        case .general:
            let notifications = NSButton(title: L("Notification settings…"), target: app, action: #selector(App.openNotificationSettings))
            rows = [
                [label(L("Startup")), loginCheck],
                [label(L("Language")), verticalStack([languagePopup, secondaryText(L("The app restarts to apply the language. It also applies to the netleash command."))])],
                [label(L("Notifications")), verticalStack([bannersCheck, notifications])],
            ]
        case .updates:
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
            rows = [
                [label(L("Version")), NSTextField(labelWithString: version)],
                [label(L("Updates")), verticalStack([dailyCheck, checkButton, updateStatus])],
            ]
        case .diagnostics:
            let logs = NSButton(title: L("Show log"), target: app, action: #selector(App.showLog))
            rows = [
                [label(L("Protection")), protectionStatus],
                [label(L("Network test")), verticalStack([testButton, secondaryText(L("Sends test HTTPS requests through the VPN and the ordinary network. Direct connections must be blocked. This does not test all DNS or privacy risks."))])],
                [label(L("Log")), verticalStack([logs, secondaryText(L("Protection, app startup, and notification events. Available even before installation."))])],
            ]
        }
        let grid = NSGridView(views: rows)
        grid.columnSpacing = 16
        grid.rowSpacing = 18
        grid.yPlacement = .top
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 126
        grid.column(at: 1).xPlacement = .leading
        grid.column(at: 1).width = 420
        grid.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -34),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
        ])
        currentGrid = grid
        window.contentView = content
        refresh()
    }
    func show() { refresh(); showWindow(window) }
    func refresh() {
        switch chosenLanguage { case "en": languagePopup.selectItem(at: 1); case "ru": languagePopup.selectItem(at: 2); default: languagePopup.selectItem(at: 0) }
        bannersCheck.state = (UserDefaults.standard.object(forKey: bannersKey) as? Bool ?? true) ? .on : .off
        dailyCheck.state = UserDefaults.standard.bool(forKey: updateDailyKey) ? .on : .off
        loginCheck.state = app.loginEnabled ? .on : .off
        refreshAvailability()
    }
    func refreshAvailability() {
        loginCheck.isEnabled = installationReady || app.loginEnabled
        loginCheck.toolTip = installationReady ? nil : L("Install Netleash to enable start at login.")
        checkButton.isEnabled = installationReady && checkButton.title != L("Checking…")
        testButton.isEnabled = app.canTestProtection
        testButton.title = app.testingProtection ? L("Testing…") : L("Test network protection…")
        protectionStatus.stringValue = installationReady ? readState().title : L("Netleash is not installed")
        if !installationReady { updateStatus.stringValue = L("Install Netleash before checking for updates.") }
        updateStatus.isHidden = updateStatus.stringValue.isEmpty
        fitContent()
    }
    private func fitContent() {
        guard let grid = currentGrid else { return }
        grid.layoutSubtreeIfNeeded()
        let size = grid.fittingSize
        let frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: ceil(size.width) + 62, height: ceil(size.height) + 48))
        let target = NSRect(x: window.frame.minX, y: window.frame.maxY - frame.height, width: frame.width, height: frame.height)
        if window.frame != target { window.setFrame(target, display: true, animate: window.isVisible) }
    }
    @objc func languageChanged() {
        let language = ["system", "en", "ru"][languagePopup.indexOfSelectedItem]
        guard language != chosenLanguage else { return }
        chosenLanguage = language
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open -n -g -a " + shellQuote(Bundle.main.bundlePath) + " --args --settings"]
        do { try p.run(); NSApp.terminate(nil) }
        catch { alert(L("Could not restart Netleash"), error.localizedDescription, style: .warning) }
    }
    @objc func bannersChanged() { UserDefaults.standard.set(bannersCheck.state == .on, forKey: bannersKey) }
    @objc func dailyChanged() { app.setDaily(dailyCheck.state == .on) }
    @objc func loginChanged() {
        let on = loginCheck.state == .on
        guard !on || installationReady else { refresh(); return }
        do { try app.setLogin(on) }
        catch { alert(L("Could not change start at login"), error.localizedDescription, style: .warning) }
        refresh()
    }
    @objc func checkNow() {
        checkButton.title = L("Checking…"); checkButton.isEnabled = false
        updateStatus.stringValue = ""
        app.checkForUpdates(userInitiated: false) { [weak self] text in
            self?.checkButton.title = L("Check for updates…")
            self?.updateStatus.stringValue = text
            self?.refreshAvailability()
        }
    }
}
