// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Netleash contributors
// netleashd — root daemon. Maintains a pf anchor that lets the protected app's group
// (default: _netleash) reach the network ONLY through the VPN's tunnel interface (and loopback).
//
// Fail-closed by construction: the "pass on utunN" rule stops matching the moment that interface
// disappears, so the kernel blocks traffic instantly, with or without this daemon. The daemon exists to
//   (a) point the rule at the new utunN after a reconnect,
//   (b) restore the pf anchor reference if somebody resets pf,
//   (c) kill protected-app processes that were started outside the launcher,
//   (d) publish status for the menu bar app and the CLI.

import Foundation
import Darwin

// MARK: - Configuration

struct Config: Codable {
    var groupName = "_netleash"
    /// The application whose network access is restricted.
    var protectedAppPath = "/Applications/Claude.app"
    /// The VPN application whose tunnel interface is the only permitted route.
    var vpnAppPath = "/Applications/AmneziaVPN.app"
    /// Kill protected-app processes that were not started through the launcher.
    var enforceLauncherOnly = true
    var notify = true
    /// Local proxy ports on loopback that the protected app must not use (they could bypass the VPN).
    var loopbackBlockPorts = [7890, 7891, 7892, 7897, 9090, 9097]
    /// Processes inside the app bundle that must not be killed as "unprotected launch". The Squirrel updater
    /// is started by launchd with another gid, does not use the network, and launchd restarts it if killed.
    var ignoreCommandSubstrings = ["/Squirrel.framework/"]
    /// DNS servers of the VPN that must never be reachable through physical interfaces. Set manually…
    var vpnDnsServers = ["100.64.0.1"]
    /// …and extended automatically: private addresses from the system resolvers that have a host route via the VPN.
    var autoDetectVpnDns = true
}

let installName = "netleash"
let configDir = "/usr/local/etc/\(installName)"
let configPath = "\(configDir)/config.json"
let stateDir = "/var/run/\(installName)"
let statusPath = "\(stateDir)/status.json"
let learnedDnsPath = "\(configDir)/learned-dns.json"
let pfTokenPath = "\(configDir)/pf-token"
// The anchor lives inside Apple's com.apple/* namespace: the stock /etc/pf.conf already references it, so
// other programs reloading the main ruleset (e.g. a VPN kill switch) do not remove our rules.
let anchorName = "com.apple/050.\(installName)"

func loadConfig() -> Config {
    guard let d = FileManager.default.contents(atPath: configPath),
          let c = try? JSONDecoder().decode(Config.self, from: d) else { return Config() }
    return c
}
let cfg = loadConfig()

// MARK: - Utilities

func log(_ s: String) {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    print("[\(f.string(from: Date()))] \(s)")
    fflush(stdout)
}

@discardableResult
func run(_ exe: String, _ args: [String], stdin: String? = nil) -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let out = Pipe(); p.standardOutput = out; p.standardError = out
    var inPipe: Pipe?
    if stdin != nil { inPipe = Pipe(); p.standardInput = inPipe }
    do { try p.run() } catch { return (-1, "\(error)") }
    if let s = stdin, let ip = inPipe {
        ip.fileHandleForWriting.write(s.data(using: .utf8)!)
        try? ip.fileHandleForWriting.close()
    }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

func groupGid() -> gid_t? {
    guard let g = getgrnam(cfg.groupName) else { return nil }
    return g.pointee.gr_gid
}

// MARK: - VPN detection

/// Returns the utun interface of the live VPN, or nil.
func detectVPNInterface() -> String? {
    let ps = run("/bin/ps", ["-axww", "-o", "command="]).out
    var candidates = Set<String>()
    let re = try! NSRegularExpression(pattern: "utun[0-9]+")
    for line in ps.split(separator: "\n") where line.contains(cfg.vpnAppPath + "/") {
        let s = String(line)
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            candidates.insert((s as NSString).substring(with: m.range))
        }
    }
    guard !candidates.isEmpty else { return nil }

    let routes = run("/usr/sbin/netstat", ["-rn", "-f", "inet"]).out
    for c in candidates.sorted() {
        let ifc = run("/sbin/ifconfig", [c]).out
        guard ifc.contains("<UP"), ifc.contains("RUNNING"), ifc.contains("inet ") else { continue }
        // The interface must carry a default-like route (default / 0/1 / 128.0/1) without the ifscope flag.
        for line in routes.split(separator: "\n") {
            let f = line.split(whereSeparator: { $0 == " " })
            guard f.count >= 4, f[3] == Substring(c) else { continue }
            if ["default", "0/1", "128.0/1"].contains(String(f[0])), !f[2].contains("I") { return c }
        }
    }
    return nil
}

// MARK: - VPN DNS (auto-detection)

var learnedDns: Set<String> = {
    guard let d = FileManager.default.contents(atPath: learnedDnsPath),
          let a = try? JSONDecoder().decode([String].self, from: d) else { return [] }
    return Set(a)
}()

func ipv4(_ s: String) -> UInt32? {
    let parts = s.split(separator: ".", omittingEmptySubsequences: false)
    let p = parts.compactMap { UInt32($0) }
    guard parts.count == 4, p.count == 4, p.allSatisfy({ $0 < 256 }) else { return nil }
    return p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]
}

/// Private/CGNAT/link-local address. Only these VPN DNS servers are blocked automatically
/// (a public one such as 8.8.8.8 may have been configured by the user for normal use).
func isPrivate(_ ip: UInt32) -> Bool {
    (ip >> 24) == 10 || (ip >> 20) == 0xAC1 || (ip >> 16) == 0xC0A8 || (ip >> 22) == (100 << 2 | 1) || (ip >> 16) == 0xA9FE
}

/// (network, mask) pairs directly attached to physical interfaces: a router's DNS there must stay reachable.
func physicalSubnets() -> [(UInt32, UInt32)] {
    var out: [(UInt32, UInt32)] = []
    for i in physicalInterfaces() {
        for line in run("/sbin/ifconfig", [i]).out.split(separator: "\n") where line.contains("inet ") {
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if let k = f.firstIndex(of: "inet"), k + 3 < f.count, f[k + 2] == "netmask",
               let a = ipv4(f[k + 1]), f[k + 3].hasPrefix("0x"), let m = UInt32(f[k + 3].dropFirst(2), radix: 16) {
                out.append((a & m, m))
            }
        }
    }
    return out
}

/// Finds the VPN's DNS servers: addresses from `scutil --dns` that have a host route via the VPN interface.
func learnVPNDNS(iface: String) {
    guard cfg.autoDetectVpnDns else { return }
    var servers = Set<String>()
    let re = try! NSRegularExpression(pattern: "nameserver\\[[0-9]+\\] : ([0-9.]+)")
    let dns = run("/usr/sbin/scutil", ["--dns"]).out
    for m in re.matches(in: dns, range: NSRange(dns.startIndex..., in: dns)) {
        servers.insert((dns as NSString).substring(with: m.range(at: 1)))
    }
    var viaVPN = Set<String>()
    for line in run("/usr/sbin/netstat", ["-rn", "-f", "inet"]).out.split(separator: "\n") {
        let f = line.split(separator: " ").map(String.init)
        if f.count >= 4, f[3] == iface, ipv4(f[0]) != nil { viaVPN.insert(f[0]) }
    }
    let subnets = physicalSubnets()
    let found = servers.intersection(viaVPN).filter { ip in
        guard let v = ipv4(ip), isPrivate(v) else { return false }
        return !subnets.contains { (v & $0.1) == $0.0 }
    }
    guard !found.isSubset(of: learnedDns) else { return }
    learnedDns.formUnion(found)
    if let d = try? JSONEncoder().encode(learnedDns.sorted()) { try? d.write(to: URL(fileURLWithPath: learnedDnsPath)) }
    log("detected VPN DNS servers: \(found.sorted().joined(separator: ", "))")
}

func vpnDnsBlockList() -> [String] {
    Set(cfg.vpnDnsServers).union(learnedDns).filter { ipv4($0) != nil }.sorted()
}

// MARK: - pf

var lastLoadedRules = ""

/// Physical interfaces (en0, en1, …) through which DNS could leave outside the VPN.
func physicalInterfaces() -> [String] {
    run("/sbin/ifconfig", ["-l"]).out.split(whereSeparator: { $0 == " " || $0 == "\n" })
        .map(String.init).filter { $0.range(of: "^en[0-9]+$", options: .regularExpression) != nil }
}

func rules(for iface: String?, dnsLock: Bool) -> String {
    let g = "group \(cfg.groupName)"
    var r = ""
    // System DNS is resolved by mDNSResponder, which is not in our group, so these two rules apply to everyone:
    // (a) the VPN's own DNS servers must never be queried through a physical interface (it happens briefly
    //     while the VPN connects: the resolver switches before the tunnel route exists);
    // (b) while the VPN is down and the protected app is running, no hostname may leave on a physical interface.
    let en = physicalInterfaces()
    if !en.isEmpty {
        let list = "{ " + en.joined(separator: ", ") + " }"
        let dns = vpnDnsBlockList()
        if !dns.isEmpty {
            r += "block drop out quick on \(list) proto { tcp, udp } from any to { \(dns.joined(separator: ", ")) } port 53\n"
        }
        if dnsLock { r += "block drop out quick on \(list) proto { tcp, udp } from any to any port { 53, 853 }\n" }
    }
    if !cfg.loopbackBlockPorts.isEmpty {
        let ports = cfg.loopbackBlockPorts.map(String.init).joined(separator: ", ")
        r += "block drop quick on lo0 proto { tcp, udp } from any to any port { \(ports) } \(g)\n"
    }
    r += "pass quick on lo0 proto { tcp, udp } all \(g) no state\n"
    if let i = iface {
        r += "pass quick on \(i) proto { tcp, udp } all \(g) keep state (if-bound)\n"
    }
    r += "block drop quick proto { tcp, udp } all \(g)\n"
    return r
}

/// Makes sure pf is enabled and the main ruleset contains `anchor "com.apple/*"`, through which our anchor runs.
func ensureMainRuleset() -> Bool {
    let info = run("/sbin/pfctl", ["-si"]).out
    let main = run("/sbin/pfctl", ["-sr"]).out
    let enabled = info.contains("Status: Enabled")
    let hooked = main.split(separator: "\n").contains { $0.hasPrefix("anchor \"com.apple/*\"") }
    if enabled && hooked { return true }

    log("pf was changed externally (enabled: \(enabled), anchor com.apple/*: \(hooked)); main ruleset:\n\(main)")
    // Restore Apple's stock ruleset, which contains anchor "com.apple/*".
    let r = run("/sbin/pfctl", ["-f", "/etc/pf.conf"])
    if r.status != 0 { log("pfctl -f failed: \(r.out)"); return false }
    if !enabled {
        let e = run("/sbin/pfctl", ["-E"]).out
        if let r = e.range(of: "Token : ") {
            let tok = e[r.upperBound...].prefix(while: { $0.isNumber })
            try? String(tok).write(toFile: pfTokenPath, atomically: true, encoding: .utf8)
        }
    }
    lastLoadedRules = ""
    log("main pf ruleset restored")
    return true
}

func applyAnchor(iface: String?, dnsLock: Bool) -> Bool {
    let text = rules(for: iface, dnsLock: dnsLock)
    if text == lastLoadedRules {
        // Verify that the kernel really holds our rules.
        let cur = run("/sbin/pfctl", ["-a", anchorName, "-sr"]).out
        if cur.contains("block drop quick proto") { return true }
    }
    let r = run("/sbin/pfctl", ["-a", anchorName, "-f", "-"], stdin: text)
    if r.status != 0 { log("failed to load anchor: \(r.out)"); return false }
    lastLoadedRules = text
    return true
}

// MARK: - Processes

struct Proc { let pid: pid_t; let gid: gid_t; let cmd: String }

/// Process list via libproc (no fork, ~3 ms): cmd is the executable path, gid is the effective gid.
func listProcesses() -> [Proc] {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(count) + 64)
    let got = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
    var out: [Proc] = []
    var path = [CChar](repeating: 0, count: 4096)
    for pid in pids.prefix(max(0, got)) where pid > 0 {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size),
              proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
        out.append(Proc(pid: pid, gid: info.pbi_gid, cmd: String(cString: path)))
    }
    return out
}

func killAll(_ ps: [Proc]) { for p in ps { kill(p.pid, SIGKILL) } }

// MARK: - Notifications

func notify(_ title: String, _ text: String) {
    guard cfg.notify else { return }
    var st = stat()
    guard stat("/dev/console", &st) == 0, st.st_uid != 0 else { return }
    let script = "display notification \"\(text)\" with title \"\(title)\""
    DispatchQueue.global().async {
        run("/bin/launchctl", ["asuser", String(st.st_uid), "/usr/bin/osascript", "-e", script])
    }
}

// MARK: - Status

func writeStatus(armed: Bool, iface: String?, note: String) {
    try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
    let d: [String: Any] = ["armed": armed, "vpnUp": iface != nil, "iface": iface ?? "",
                            "ts": Date().timeIntervalSince1970, "pid": getpid(), "note": note]
    if let data = try? JSONSerialization.data(withJSONObject: d) {
        try? data.write(to: URL(fileURLWithPath: statusPath), options: .atomic)
        chmod(statusPath, 0o644)
    }
}

// MARK: - Main loop

guard geteuid() == 0 else { fputs("netleashd must run as root\n", stderr); exit(1) }
setvbuf(stdout, nil, _IOLBF, 0)
log("started; group \(cfg.groupName), protected app \(cfg.protectedAppPath), VPN app \(cfg.vpnAppPath)")

var lastIface: String?? = .none
var effectiveIface: String?
var nilStreak = 0
var lastRogueNotify = Date.distantPast
var cachedGid: gid_t?
var tickCount = 0
var lastLearnIface: String?

/// Fast check (every 50 ms): any process from the protected app that is outside the group is killed at once.
func scanRogue() {
    guard cfg.enforceLauncherOnly, let gid = cachedGid else { return }
    let prefix = cfg.protectedAppPath + "/"
    let rogue = listProcesses().filter { p in
        p.cmd.hasPrefix(prefix) && p.gid != gid && !cfg.ignoreCommandSubstrings.contains(where: { p.cmd.contains($0) })
    }
    guard !rogue.isEmpty else { return }
    killAll(rogue)
    log("unprotected launch of the protected app (\(rogue.count) processes) terminated")
    if Date().timeIntervalSince(lastRogueNotify) > 60 {
        notify("App closed", "Start it only through Netleash.")
        lastRogueNotify = Date()
    }
}

func tick() {
    guard let gid = groupGid() else {
        writeStatus(armed: false, iface: nil, note: "group \(cfg.groupName) is missing")
        log("group \(cfg.groupName) not found"); return
    }
    cachedGid = gid
    // A single failed detection (ps/netstat hiccup) must not flap rules and notifications:
    // "no VPN" is accepted after 3 consecutive misses (1.5 s). A real disconnect is blocked by the kernel anyway.
    if let raw = detectVPNInterface() { nilStreak = 0; effectiveIface = raw }
    else { nilStreak += 1; if nilStreak >= 3 { effectiveIface = nil } }
    let iface = effectiveIface
    tickCount += 1
    if let i = iface, i != lastLearnIface || tickCount % 20 == 0 { learnVPNDNS(iface: i); lastLearnIface = i }
    let mainOK = ensureMainRuleset()
    let procs = listProcesses()
    let appRunning = procs.contains { $0.gid == gid && $0.cmd.hasPrefix(cfg.protectedAppPath + "/") }
    let anchorOK = mainOK && applyAnchor(iface: iface, dnsLock: iface == nil && appRunning)
    let armed = mainOK && anchorOK

    if !armed {
        // We cannot guarantee blocking: stop everything that is in the protected group.
        let victims = procs.filter { $0.gid == gid && $0.pid != getpid() }
        if !victims.isEmpty { log("protection is not armed, killing \(victims.count) processes"); killAll(victims) }
        writeStatus(armed: false, iface: iface, note: "pf is not armed")
    } else {
        writeStatus(armed: true, iface: iface,
                    note: iface == nil ? "VPN is down: network of the protected app is blocked"
                                       : "VPN \(iface!): network of the protected app is allowed only through it")
    }

    if lastIface == nil || lastIface! != iface {
        if lastIface != nil {
            log(iface == nil ? "VPN down -> protected app blocked" : "VPN up (\(iface!)) -> protected app allowed")
            // Notify only while a protected app is running.
            if appRunning {
                notify(iface == nil ? "VPN disconnected" : "VPN connected",
                       iface == nil ? "Network access is blocked." : "Network access restored through the VPN.")
            }
        } else {
            log(iface == nil ? "VPN is not connected" : "VPN: \(iface!)")
        }
        lastIface = .some(iface)
    }
}

signal(SIGTERM) { _ in log("SIGTERM - anchor stays in the kernel (fail-closed)"); exit(0) }
signal(SIGPIPE, SIG_IGN)

let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now(), repeating: .milliseconds(500))
timer.setEventHandler { tick() }
timer.resume()

let fastTimer = DispatchSource.makeTimerSource(queue: .main)
fastTimer.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(5))
fastTimer.setEventHandler { scanRogue() }
fastTimer.resume()
dispatchMain()
