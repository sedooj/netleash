// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Netleash contributors

import Foundation

struct CommandResult {
    let output: String
    let exitCode: Int32?
    let error: Error?
    let timedOut: Bool
}

/// Capture to a private file, so a failed spawn or a child retaining stdout cannot hold an EOF read open.
/// Call from a background queue. Both starting and waiting have explicit failure paths.
func runCommand(_ path: String, _ arguments: [String], timeout: TimeInterval) -> CommandResult {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("netleash-command-" + UUID().uuidString)
    guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
        return CommandResult(output: "", exitCode: nil, error: CocoaError(.fileWriteUnknown), timedOut: false)
    }
    defer { try? FileManager.default.removeItem(at: url) }
    do {
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = file
        process.standardError = file
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        let timedOut = finished.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 0.5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 0.5)
            }
        }
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        let data = try reader.read(upToCount: 512 * 1024) ?? Data()
        return CommandResult(output: String(decoding: data, as: UTF8.self),
                             exitCode: timedOut ? nil : process.terminationStatus, error: nil, timedOut: timedOut)
    } catch {
        return CommandResult(output: "", exitCode: nil, error: error, timedOut: false)
    }
}
