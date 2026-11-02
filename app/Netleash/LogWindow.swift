// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Netleash contributors

import AppKit

final class LogWindow: NSObject {
    let window: NSWindow
    let sources = NSPopUpButton(frame: .zero, pullsDown: false)
    let text = NSTextView()
    let status = secondaryText("", width: 700)
    let paths = [logPath, NSHomeDirectory() + "/Library/Logs/Netleash.log", launchLog, "/var/log/netleash-install.log"]

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 440),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = L("Netleash log")
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 560, height: 300)
        sources.addItems(withTitles: [L("Protection"), L("Netleash app"), L("Application startup"), L("Installation")])
        sources.target = self; sources.action = #selector(refresh)
        let refresh = NSButton(title: L("Refresh"), target: self, action: #selector(refresh))
        let heading = NSStackView(views: [sources, NSView(), refresh])
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        text.isEditable = false
        text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textContainerInset = NSSize(width: 14, height: 12)
        text.isHorizontallyResizable = true
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.containerSize = NSSize(width: 10000, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = text
        let body = verticalStack([heading, scroll, status], spacing: 12)
        body.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(body)
        window.contentView = content
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            body.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            body.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            body.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            heading.widthAnchor.constraint(equalTo: body.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: body.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            status.widthAnchor.constraint(equalTo: body.widthAnchor),
        ])
    }
    func show() { refresh(); showWindow(window) }
    @objc func refresh() {
        var path = paths[max(0, sources.indexOfSelectedItem)]
        // Include failures from older launchers which died before install.sh could create its own log.
        if sources.indexOfSelectedItem == 3 && !FileManager.default.fileExists(atPath: path),
           FileManager.default.fileExists(atPath: "/var/log/netleash-update.log") {
            path = "/var/log/netleash-update.log"
        }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw CocoaError(.fileReadUnknown) }
            let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? file.close() }
            let end = try file.seekToEnd()
            let offset = end > 256 * 1024 ? end - 256 * 1024 : 0
            try file.seek(toOffset: offset)
            var data = try file.read(upToCount: 256 * 1024) ?? Data()
            // A tail read may begin in the middle of a UTF-8 line. Drop only the partial first line.
            if offset > 0, let newline = data.firstIndex(of: 10) { data = Data(data.suffix(from: data.index(after: newline))) }
            text.string = data.isEmpty ? L("No entries yet.") : String(decoding: data, as: UTF8.self)
            status.stringValue = path
            text.scrollToEndOfDocument(nil)
        } catch {
            text.string = ""
            if !FileManager.default.fileExists(atPath: path) {
                status.stringValue = sources.indexOfSelectedItem == 0 && !installationReady ? L("No protection log yet. Install Netleash to start the background service.") : L("No entries yet. Events will appear here after the service or app starts.")
            } else {
                status.stringValue = L("Could not read this log. Check file access and try Refresh.")
            }
        }
    }
}
