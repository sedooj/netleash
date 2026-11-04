// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Netleash contributors

import Foundation

@main
struct CommandRunnerTests {
    static func main() {
        let missing = runCommand("/nonexistent/netleash", [], timeout: 0.2)
        precondition(missing.error != nil && missing.exitCode == nil && !missing.timedOut, "A missing tool must report an error without reading a pipe")
        let normal = runCommand("/bin/sh", ["-c", "printf 'out'; printf 'err' >&2; exit 17"], timeout: 2)
        precondition(normal.output == "outerr" && normal.exitCode == 17 && normal.error == nil)
        let before = Date()
        let inherited = runCommand("/bin/sh", ["-c", "/bin/sleep 2 & printf 'done'"], timeout: 3)
        precondition(inherited.output == "done" && inherited.exitCode == 0)
        precondition(Date().timeIntervalSince(before) < 1.5, "An unrelated child retaining stdout must not block the result")
        let hung = runCommand("/bin/sh", ["-c", "trap '' TERM; exec /bin/sleep 10"], timeout: 0.1)
        precondition(hung.timedOut && hung.exitCode == nil, "An unresponsive command must be stopped")
        let retry = runCommand("/bin/echo", ["retry"], timeout: 2)
        precondition(retry.exitCode == 0 && retry.output == "retry\n", "A new command must work after a timeout")
        for width in [CGFloat(656), 712, 1100] {
            let row = ApplicationRowLayout(width: width, openWidth: 65, shortcutWidth: 74)
            precondition(row.remove.maxX == width - 14, "Actions must stay at the right edge")
            precondition(row.name.width > 200 && row.name.width == row.status.width && row.name.width == row.path.width)
            precondition(row.name.maxX + 16 == row.open.minX, "Text must consume the remaining width")
            precondition(row.open.maxX < row.shortcut.minX && row.shortcut.maxX < row.toggle.minX && row.toggle.maxX < row.remove.minX)
        }
        let narrow = ApplicationRowLayout(width: 656, openWidth: 65, shortcutWidth: 74)
        let wide = ApplicationRowLayout(width: 1100, openWidth: 65, shortcutWidth: 74)
        precondition(wide.name.width - narrow.name.width == 444, "Extra window width must grow the text column")
        print("OK: missing executable, nonzero exit, inherited stdout, timeout, and retry")
        print("OK: app rows fill narrow/wide windows, text grows, actions remain aligned")
        do { try ShortcutMetadataTests.run() }
        catch { fatalError("Shortcut metadata regression: \(error)") }
    }
}
