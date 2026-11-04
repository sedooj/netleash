// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Netleash contributors

import AppKit
import UniformTypeIdentifiers

func secondaryText(_ text: String, width: CGFloat = 420) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = .systemFont(ofSize: 11)
    label.textColor = .secondaryLabelColor
    label.preferredMaxLayoutWidth = width
    return label
}

func verticalStack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = spacing
    return stack
}

func showWindow(_ window: NSWindow) {
    if !window.isVisible { window.center() }
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
}

final class ApplicationListDocument: NSView {
    override var isFlipped: Bool { true }
}

final class ApplicationsListView: NSScrollView {
    private let document = ApplicationListDocument()
    private var rows: [NSView] = []
    private var updatingLayout = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        hasVerticalScroller = true
        autohidesScrollers = true
        borderType = .bezelBorder
        backgroundColor = .controlBackgroundColor
        documentView = document
    }
    required init?(coder: NSCoder) { return nil }
    func setRows(_ views: [NSView]) {
        rows.forEach { $0.removeFromSuperview() }
        rows = views
        rows.forEach { document.addSubview($0) }
        layoutRows()
    }
    override func tile() { super.tile(); layoutRows() }
    override func layout() { super.layout(); layoutRows() }
    private func layoutRows() {
        guard !updatingLayout else { return }
        updatingLayout = true
        defer { updatingLayout = false }
        let width = contentView.bounds.width
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(contentView.bounds.height, CGFloat(rows.count) * 84))
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: 0, y: CGFloat(index) * 84, width: width, height: 84)
            row.needsLayout = true
            row.layoutSubtreeIfNeeded()
        }
    }
}

/// The scroll viewport owns row width; text consumes the space left by the right-aligned controls.
final class ApplicationRowView: NSView {
    let icon: NSImageView
    let name: NSTextField
    let status: NSTextField
    let path: NSTextField
    let open: NSButton
    let shortcut: NSButton
    let toggle: NSSwitch
    let remove: NSButton
    let separator = NSBox()

    init(icon: NSImageView, name: NSTextField, status: NSTextField, path: NSTextField,
         open: NSButton, shortcut: NSButton, toggle: NSSwitch, remove: NSButton) {
        self.icon = icon; self.name = name; self.status = status; self.path = path
        self.open = open; self.shortcut = shortcut; self.toggle = toggle; self.remove = remove
        super.init(frame: NSRect(x: 0, y: 0, width: 700, height: 84))
        separator.boxType = .separator
        [icon, name, status, path, open, shortcut, toggle, remove, separator].forEach { addSubview($0) }
    }
    required init?(coder: NSCoder) { return nil }
    override func layout() {
        super.layout()
        let frames = ApplicationRowLayout(width: bounds.width, height: bounds.height,
                                          openWidth: open.fittingSize.width, shortcutWidth: shortcut.fittingSize.width)
        icon.frame = frames.icon; name.frame = frames.name; status.frame = frames.status; path.frame = frames.path
        open.frame = frames.open; shortcut.frame = frames.shortcut; toggle.frame = frames.toggle; remove.frame = frames.remove
        separator.frame = frames.separator
    }
}

final class ApplicationsWindow: NSObject {
    unowned let app: App
    let window: NSWindow
    let listView = ApplicationsListView(frame: .zero)
    let empty = NSTextField(labelWithString: L("No protected applications"))
    let installationBox = NSBox()
    let installTitle = NSTextField(labelWithString: "")
    let installNote = secondaryText("", width: 490)
    let installButton = NSButton(title: "", target: nil, action: nil)
    let summary = NSTextField(labelWithString: "")
    let addClaude = NSButton(title: L("Add Claude"), target: nil, action: nil)
    let addCodex = NSButton(title: L("Add Codex"), target: nil, action: nil)
    let addOther = NSButton(title: L("Choose application…"), target: nil, action: nil)
    var apps: [ProtectedApplication] = []
    var applicationsTimer: Timer?
    var applicationsSnapshot = ""
    var changingApplications = false

    init(app: App) {
        self.app = app
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Netleash"
        window.contentMinSize = NSSize(width: 720, height: 440)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("NetleashApplications")
        let title = NSTextField(labelWithString: L("Protected applications"))
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        summary.font = .systemFont(ofSize: 12)
        summary.textColor = .secondaryLabelColor
        let settings = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: L("Settings…"))!, target: app, action: #selector(App.openSettings))
        settings.bezelStyle = .rounded
        settings.toolTip = L("Settings…")
        let heading = NSStackView(views: [verticalStack([title, summary], spacing: 5), NSView(), settings])
        heading.alignment = .centerY

        installationBox.boxType = .custom
        installationBox.borderColor = .separatorColor
        installationBox.fillColor = .controlBackgroundColor
        installationBox.cornerRadius = 8
        installationBox.contentViewMargins = NSSize(width: 14, height: 12)
        installTitle.stringValue = L("Netleash is not installed")
        installTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        installNote.stringValue = L("Install the protection service to manage apps and run checks.")
        installButton.target = app
        installButton.action = #selector(App.installNetleash)
        installButton.title = L("Install…")
        let banner = NSStackView(views: [verticalStack([installTitle, installNote], spacing: 4), NSView(), installButton])
        banner.translatesAutoresizingMaskIntoConstraints = false
        installationBox.contentView!.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.leadingAnchor.constraint(equalTo: installationBox.contentView!.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: installationBox.contentView!.trailingAnchor),
            banner.topAnchor.constraint(equalTo: installationBox.contentView!.topAnchor),
            banner.bottomAnchor.constraint(equalTo: installationBox.contentView!.bottomAnchor),
        ])

        let scroll = listView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let list = NSView()
        list.addSubview(scroll)
        empty.textColor = .secondaryLabelColor
        empty.translatesAutoresizingMaskIntoConstraints = false
        list.addSubview(empty)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: list.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: list.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: list.topAnchor), scroll.bottomAnchor.constraint(equalTo: list.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: list.centerXAnchor), empty.centerYAnchor.constraint(equalTo: list.centerYAnchor),
            list.heightAnchor.constraint(greaterThanOrEqualToConstant: 130),
        ])
        list.setContentHuggingPriority(.defaultLow, for: .vertical)
        addClaude.target = self; addClaude.action = #selector(addClaudeApp)
        addCodex.target = self; addCodex.action = #selector(addCodexApp)
        addOther.target = self; addOther.action = #selector(chooseApplication)
        let buttons = NSStackView(views: [addClaude, addCodex, addOther])
        buttons.spacing = 8
        let note = secondaryText(L("Open apps here or use a desktop shortcut. Restart an app after changing its protection."), width: 712)
        let body = verticalStack([heading, installationBox, list, buttons, note], spacing: 14)
        body.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(body)
        window.contentView = content
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            body.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            body.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            body.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -22),
            heading.widthAnchor.constraint(equalTo: body.widthAnchor),
            installationBox.widthAnchor.constraint(equalTo: body.widthAnchor),
            list.widthAnchor.constraint(equalTo: body.widthAnchor),
            note.widthAnchor.constraint(equalTo: body.widthAnchor),
        ])
        applicationsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.window.isVisible else { return }
            self.refresh()
        }
        refresh()
    }

    deinit { applicationsTimer?.invalidate() }
    func show() { refresh(); showWindow(window) }
    func refresh() {
        guard !changingApplications else { return }
        let installed = installationReady
        installationBox.isHidden = app.canManageApplications
        installTitle.stringValue = installed ? L("Protection is stopped") : L("Netleash is not installed")
        installNote.stringValue = app.installationNotice ?? (installed ? L("Start protection to manage and launch protected apps.") : L("Install the protection service to manage apps and run checks."))
        installButton.title = installed ? L("Restore protection") : L("Install…")
        installButton.action = installed ? #selector(App.resume) : #selector(App.installNetleash)
        installButton.isEnabled = !app.installingProtection
        if app.installingProtection {
            installButton.title = L("Installing…")
            installNote.stringValue = L("Installing the protection service. Netleash will reopen when it is ready.")
        }
        summary.stringValue = installed ? readState().title : L("Set up network protection for your apps")
        [addClaude, addCodex, addOther].forEach { $0.isEnabled = app.canManageApplications }
        let configured = FileManager.default.fileExists(atPath: configPath) ? protectedApplications() : []
        let snapshot = "\(installed)|\(app.canManageApplications)" + configured.map { "\($0.path)|\($0.enabled)|\($0.status)" }.joined(separator: "\n")
        guard snapshot != applicationsSnapshot else { return }
        applicationsSnapshot = snapshot
        apps = configured
        empty.isHidden = !apps.isEmpty
        listView.setRows(apps.map(makeRow))
    }
    func makeRow(_ a: ProtectedApplication) -> NSView {
        let icon = NSImageView()
        icon.image = NSWorkspace.shared.icon(forFile: a.path)
        let name = NSTextField(labelWithString: a.name)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        let status = NSTextField(labelWithString: a.status)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        let path = NSTextField(labelWithString: a.path)
        path.font = .systemFont(ofSize: 10)
        path.textColor = .tertiaryLabelColor
        path.toolTip = a.path
        for label in [name, status, path] {
            label.lineBreakMode = .byTruncatingMiddle
            label.maximumNumberOfLines = 1
        }
        let open = NSButton(title: L("Open"), target: self, action: #selector(openApplication(_:)))
        let shortcut = NSButton(title: L("Shortcut…"), target: self, action: #selector(createApplicationShortcut(_:)))
        let toggle = NSSwitch()
        toggle.target = self; toggle.action = #selector(toggleApplication(_:))
        toggle.state = a.enabled ? .on : .off
        toggle.setAccessibilityLabel(L("Protection for %@", a.name))
        let remove = NSButton(image: NSImage(systemSymbolName: "minus.circle", accessibilityDescription: L("Remove application"))!, target: self, action: #selector(removeApplication(_:)))
        remove.isBordered = false
        remove.toolTip = L("Remove application")
        for control in [open, shortcut, toggle, remove] as [NSControl] {
            control.identifier = NSUserInterfaceItemIdentifier(a.path)
            control.controlSize = .small
            control.isEnabled = app.canManageApplications
        }
        open.isEnabled = app.canManageApplications && a.enabled && a.installed
        shortcut.isEnabled = a.installed
        shortcut.toolTip = L("Create a desktop shortcut with the original app icon")
        return ApplicationRowView(icon: icon, name: name, status: status, path: path,
                                  open: open, shortcut: shortcut, toggle: toggle, remove: remove)
    }
    func changeApplication(_ action: String, _ path: String) {
        guard !changingApplications else { return }
        guard app.requireInstallation() else { refresh(); return }
        guard app.canManageApplications else { refresh(); return }
        if action == "add" || action == "enable" {
            let a = ProtectedApplication(path: path, enabled: true)
            if a.running {
                alert(L("Close the app first"), L("Save your work and quit %@ before enabling protection. Then launch it from Netleash.", a.name))
                applicationsSnapshot = ""; refresh()
                return
            }
        }
        changingApplications = true
        // All dynamic arguments are shell-quoted before entering the administrator prompt.
        let command = ["\(libexec)/netleash", "apps", action, path].map(shellQuote).joined(separator: " ")
        let result = runAsAdmin(command)
        changingApplications = false
        if case .failure(let message) = result { alert(L("Could not apply application settings"), message, style: .warning) }
        applicationsSnapshot = ""
        refresh()
        app.rebuildApplicationsMenu()
    }

    @objc func toggleApplication(_ sender: NSSwitch) {
        guard let path = sender.identifier?.rawValue else { return }
        changeApplication(sender.state == .on ? "enable" : "disable", path)
    }
    @objc func removeApplication(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        changeApplication("remove", path)
    }
    @objc func openApplication(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        app.openProtectedApp(path)
    }
    @objc func createApplicationShortcut(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue,
              let application = protectedApplications().first(where: { $0.path == path }) else { return }
        let panel = NSSavePanel()
        panel.title = L("Create desktop shortcut")
        panel.prompt = L("Create")
        panel.allowedContentTypes = [.aliasFile]
        panel.isExtensionHidden = true
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        let name = application.name.components(separatedBy: CharacterSet(charactersIn: "/:").union(.controlCharacters)).joined(separator: "-")
        panel.nameFieldStringValue = name + ".alias"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try createShortcut(for: application, at: destination)
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch {
            alert(L("Could not create shortcut"), error.localizedDescription, style: .critical)
        }
    }
    func addPreset(_ name: String) {
        let identifier = name == "Codex" ? "com.openai.codex" : "com.anthropic.claudefordesktop"
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
            addApplication(url)
            return
        }
        let candidates = ["/Applications/\(name).app", NSHomeDirectory() + "/Applications/\(name).app"]
        if let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            addApplication(URL(fileURLWithPath: path))
        } else { chooseApplication() }
    }
    func addApplication(_ url: URL) {
        let path = url.resolvingSymlinksInPath().path
        if let a = protectedApplications().first(where: { $0.path == path }) {
            if !a.enabled { changeApplication("enable", path) }
            return
        }
        changeApplication("add", path)
    }
    @objc func addClaudeApp() { addPreset("Claude") }
    @objc func addCodexApp() { addPreset("Codex") }
    @objc func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = L("Choose application…")
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        if panel.runModal() == .OK, let url = panel.url { addApplication(url) }
    }

}
