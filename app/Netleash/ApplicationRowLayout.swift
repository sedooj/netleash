// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Netleash contributors

import Foundation
import CoreGraphics

struct ApplicationRowLayout {
    let icon, name, status, path, open, shortcut, toggle, remove, separator: CGRect

    init(width: CGFloat, height: CGFloat = 84, openWidth: CGFloat, shortcutWidth: CGFloat) {
        let center = height / 2
        var right = width - 14
        func place(_ width: CGFloat, _ height: CGFloat, gap: CGFloat) -> CGRect {
            let frame = CGRect(x: right - width, y: center - height / 2, width: width, height: height)
            right -= width + gap
            return frame
        }
        remove = place(24, 24, gap: 10)
        toggle = place(42, 24, gap: 12)
        shortcut = place(max(76, shortcutWidth), 26, gap: 8)
        open = place(max(72, openWidth), 26, gap: 16)
        icon = CGRect(x: 14, y: center - 16, width: 32, height: 32)
        let textWidth = max(0, right - 58)
        name = CGRect(x: 58, y: center + 11, width: textWidth, height: 18)
        status = CGRect(x: 58, y: center - 9, width: textWidth, height: 16)
        path = CGRect(x: 58, y: center - 26, width: textWidth, height: 14)
        separator = CGRect(x: 14, y: 0, width: max(0, width - 28), height: 1)
    }
}
