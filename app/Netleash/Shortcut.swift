// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Netleash contributors

import AppKit

enum ShortcutError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

/// Builds a small native launcher. The original app and its signature are never modified.
func createShortcut(for application: ProtectedApplication, at destination: URL) throws {
    let fm = FileManager.default
    let target = application.url.resolvingSymlinksInPath()
    guard destination.isFileURL, ["app", "alias"].contains(destination.pathExtension.lowercased()), target.pathExtension == "app", application.installed,
          let launcher = Bundle.main.url(forResource: "NetleashLauncher", withExtension: nil),
          fm.isExecutableFile(atPath: launcher.path) else {
        throw ShortcutError.message(L("Could not create shortcut. Check that both apps are installed correctly."))
    }
    guard !fm.fileExists(atPath: destination.path) else {
        throw ShortcutError.message(L("A file already exists there. Choose another name or location."))
    }
    // Build privately rather than inside Desktop/iCloud, where Finder may annotate intermediate files.
    let temporary = fm.temporaryDirectory.appendingPathComponent("netleash-shortcut-" + UUID().uuidString)
    try fm.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: temporary) }
    let staged = temporary.appendingPathComponent("Launcher.app")
    let contents = staged.appendingPathComponent("Contents")
    let macOS = contents.appendingPathComponent("MacOS")
    let resources = contents.appendingPathComponent("Resources")
    try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
    try fm.createDirectory(at: resources, withIntermediateDirectories: true)
    try fm.copyItem(at: launcher, to: macOS.appendingPathComponent("NetleashLauncher"))
    let icon = resources.appendingPathComponent("AppIcon.icns")
    if let original = originalAppIcon(at: target) {
        // Copy the data fork, not Finder metadata or an already-composited, scaled system image.
        try original.write(to: icon)
    } else {
        try writeShortcutIcon(NSWorkspace.shared.icon(forFile: target.path), to: icon, temporary: temporary)
    }
    if let translations = Bundle.main.url(forResource: "ru", withExtension: "lproj") {
        try fm.copyItem(at: translations, to: resources.appendingPathComponent("ru.lproj"))
    }
    let identifier = "org.netleash.shortcut." + UUID().uuidString.lowercased()
    let plist: [String: Any] = [
        "CFBundleName": destination.deletingPathExtension().lastPathComponent,
        "CFBundleDisplayName": destination.deletingPathExtension().lastPathComponent,
        "CFBundleIdentifier": identifier,
        "CFBundleExecutable": "NetleashLauncher", "CFBundlePackageType": "APPL",
        "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
        "CFBundleIconFile": "AppIcon.icns", "CFBundleDevelopmentRegion": "en",
        "CFBundleLocalizations": ["en", "ru"], "LSMinimumSystemVersion": "13.0",
        "LSUIElement": true, "NetleashTargetAppPath": target.path,
    ]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
    try removeShortcutSigningMetadata(at: staged)
    try runShortcutTool("/usr/bin/codesign", ["--force", "--sign", "-", staged.path])
    // Keep signed code outside synced Desktop/Document folders. File providers can add FinderInfo
    // asynchronously even after a successful codesign verification. Only an unsigned Finder alias
    // belongs at the requested destination; its metadata cannot invalidate the signed launcher.
    let storedRoot = URL(fileURLWithPath: supportDir).appendingPathComponent("Launchers").appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: storedRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var published = false
    defer { if !published { try? fm.removeItem(at: storedRoot) } }
    let stored = storedRoot.appendingPathComponent(destination.deletingPathExtension().lastPathComponent + ".app")
    try fm.moveItem(at: staged, to: stored)
    try removeShortcutSigningMetadata(at: stored)
    try runShortcutTool("/usr/bin/codesign", ["--verify", "--strict", stored.path])
    let bookmark = try stored.bookmarkData(options: [.suitableForBookmarkFile, .withoutImplicitSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    var alias = temporary.appendingPathComponent("Shortcut.alias")
    try URL.writeBookmarkData(bookmark, to: alias)
    var values = URLResourceValues()
    values.hasHiddenExtension = true
    try alias.setResourceValues(values)
    let aliasBytes = try Data(contentsOf: alias)
    // moveItem refuses a collision, including one created after the initial existence check.
    try fm.moveItem(at: alias, to: destination)
    do {
        let resolved = try resolveShortcutAlias(at: destination, expected: stored)
        try runShortcutTool("/usr/bin/codesign", ["--verify", "--strict", resolved.path])
        published = true
    } catch {
        if (try? Data(contentsOf: destination)) == aliasBytes { try? fm.removeItem(at: destination) }
        throw error
    }
}

func originalAppIcon(at application: URL) -> Data? {
    guard let bundle = Bundle(url: application),
          let name = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
          !name.isEmpty, (name as NSString).lastPathComponent == name,
          let resources = bundle.resourceURL?.resolvingSymlinksInPath() else { return nil }
    let filename = (name as NSString).pathExtension.isEmpty ? name + ".icns" : name
    guard (filename as NSString).pathExtension.lowercased() == "icns" else { return nil }
    let icon = resources.appendingPathComponent(filename).resolvingSymlinksInPath()
    guard icon.path.hasPrefix(resources.path + "/"),
          let attributes = try? FileManager.default.attributesOfItem(atPath: icon.path),
          attributes[.type] as? FileAttributeType == .typeRegular,
          let size = attributes[.size] as? NSNumber, size.intValue <= 32 * 1024 * 1024,
          let data = try? Data(contentsOf: icon), data.count >= 8,
          data.prefix(4) == Data([0x69, 0x63, 0x6e, 0x73]) else { return nil }
    return data
}

private func runShortcutTool(_ path: String, _ arguments: [String]) throws {
    let result = runCommand(path, arguments, timeout: 15)
    if result.timedOut { throw ShortcutError.message(L("Shortcut creation timed out. Try again.")) }
    if let error = result.error { throw error }
    if result.exitCode != 0 { throw ShortcutError.message(result.output) }
}

private func writeShortcutIcon(_ image: NSImage, to destination: URL, temporary: URL) throws {
    let fm = FileManager.default
    let iconset = temporary.appendingPathComponent("AppIcon.iconset")
    try fm.createDirectory(at: iconset, withIntermediateDirectories: false)
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let pixels = size * scale
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                let context = NSGraphicsContext(bitmapImageRep: rep) else { throw ShortcutError.message(L("Could not copy the application icon.")) }
            // Bitmap contexts use pixels; iconutil gets the Retina scale from the @2x filename.
            // Drawing point dimensions here produced a half-sized logo in the lower-left quadrant.
            rep.size = NSSize(width: pixels, height: pixels)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            guard let data = rep.representation(using: .png, properties: [:]) else { throw ShortcutError.message(L("Could not copy the application icon.")) }
            let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
            try data.write(to: iconset.appendingPathComponent(name))
        }
    }
    try runShortcutTool("/usr/bin/iconutil", ["--convert", "icns", "--output", destination.path, iconset.path])
}
