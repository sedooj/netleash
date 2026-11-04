// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Netleash contributors

import Foundation
import Darwin

enum ShortcutMetadataTests {
    static func run() throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("netleash-metadata-test-" + UUID().uuidString)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: temporary) }
        let original = temporary.appendingPathComponent("original")
        try Data("original".utf8).write(to: original)
        let finder = Data(repeating: 1, count: 32)
        let resource = Data("resource".utf8)
        try set(original, "com.apple.FinderInfo", finder)
        try set(original, "com.apple.ResourceFork", resource)
        let bundle = temporary.appendingPathComponent("Generated.app")
        let resources = bundle.appendingPathComponent("Contents/Resources")
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        let copied = resources.appendingPathComponent("copied")
        try fm.copyItem(at: original, to: copied)
        precondition(read(copied, "com.apple.FinderInfo") == finder, "Fixture must reproduce metadata preserved by copyItem")
        let keep = Data("keep this metadata".utf8)
        try set(copied, "com.netleash.test", keep)
        try set(bundle, "com.apple.FinderInfo", finder)
        try fm.createSymbolicLink(at: resources.appendingPathComponent("outside-link"), withDestinationURL: original)
        try removeShortcutSigningMetadata(at: bundle)
        try removeShortcutSigningMetadata(at: bundle)
        precondition(read(copied, "com.apple.FinderInfo") == nil && read(copied, "com.apple.ResourceFork") == nil)
        precondition(read(bundle, "com.apple.FinderInfo") == nil)
        precondition(read(copied, "com.netleash.test") == keep, "Unrelated metadata must be preserved")
        precondition(read(original, "com.apple.FinderInfo") == finder && read(original, "com.apple.ResourceFork") == resource,
                     "Cleaning the copy must not modify the source or follow a symlink")
        let target = temporary.appendingPathComponent("Application Support/Launcher.app")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let alias = temporary.appendingPathComponent("Claude.alias")
        let bookmark = try target.bookmarkData(options: [.suitableForBookmarkFile, .withoutImplicitSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(bookmark, to: alias)
        let resolved = try resolveShortcutAlias(at: alias, expected: target)
        precondition(resolved.resolvingSymlinksInPath().path == target.resolvingSymlinksInPath().path)
        do {
            _ = try resolveShortcutAlias(at: alias, expected: bundle)
            fatalError("Accepted a shortcut pointing at the wrong launcher")
        } catch is CocoaError { }
        print("OK: shortcut metadata cleaned; original, symlink targets, and unrelated attributes preserved")
        print("OK: native Finder alias resolves correctly across directory-URL formatting differences")
    }

    private static func set(_ url: URL, _ name: String, _ data: Data) throws {
        let result = data.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) }
        if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    private static func read(_ url: URL, _ name: String) -> Data? {
        let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { return nil }
        var data = Data(count: size)
        let result = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        return result == size ? data : nil
    }
}
