// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Netleash contributors

import Foundation
import Darwin

func resolveShortcutAlias(at alias: URL, expected: URL) throws -> URL {
    guard try alias.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile == true else { throw CocoaError(.fileReadCorruptFile) }
    let resolved = try URL(resolvingAliasFileAt: alias, options: [.withoutUI, .withoutMounting])
    // Bookmark URLs for directories carry a trailing slash which a pre-creation URL may not.
    guard resolved.resolvingSymlinksInPath().path == expected.resolvingSymlinksInPath().path else { throw CocoaError(.fileReadCorruptFile) }
    return resolved
}

/// Remove only attributes codesign rejects, and only from the newly generated shortcut.
/// Do not follow symlinks or clear quarantine, provenance, tags, or attributes of the source app.
func removeShortcutSigningMetadata(at bundle: URL) throws {
    let fm = FileManager.default
    let root = try bundle.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard bundle.isFileURL, root.isDirectory == true, root.isSymbolicLink != true else { throw CocoaError(.fileWriteInvalidFileName) }
    var enumerationError: Error?
    guard let entries = fm.enumerator(at: bundle, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [], errorHandler: { _, error in
        enumerationError = error
        return false
    }) else { throw CocoaError(.fileReadUnknown) }
    let paths = [bundle] + entries.compactMap { $0 as? URL }
    if let enumerationError { throw enumerationError }
    for path in paths {
        if try path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { continue }
        for attribute in ["com.apple.FinderInfo", "com.apple.ResourceFork"] {
            if removexattr(path.path, attribute, XATTR_NOFOLLOW) != 0 && errno != ENOATTR {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO, userInfo: [NSFilePathErrorKey: path.path])
            }
        }
    }
}
