// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Netleash contributors
// netleash-exec — setuid-root helper. Runs a command as the CALLING user, but with a single
// group, _netleash (all supplementary groups dropped, and the original gid cannot be regained).
// The pf anchor maintained by netleashd restricts the network of that group. The helper only ever
// LOWERS privileges, so running an arbitrary command through it grants nothing beyond what the user already has.

import Foundation
import Darwin

func die(_ msg: String, _ code: Int32 = 1) -> Never {
    fputs("netleash-exec: \(msg)\n", stderr)
    exit(code)
}

guard CommandLine.arguments.count >= 2 else { die("usage: netleash-exec <program> [arguments...]", 64) }
guard geteuid() == 0 else { die("not setuid root (run install.sh)") }

let realUid = getuid()
let origGid = getgid()
guard realUid != 0 else { die("do not run as root") }
guard let grp = getgrnam("_netleash") else { die("group _netleash not found") }
var gid = grp.pointee.gr_gid

// The daemon must be alive and armed, otherwise we refuse to start.
guard let data = FileManager.default.contents(atPath: "/var/run/netleash/status.json"),
      let st = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let ts = st["ts"] as? Double, (st["armed"] as? Bool) == true,
      Date().timeIntervalSince1970 - ts < 5 else {
    die("protection is not active (daemon not running or pf not armed). Check: netleash status", 2)
}

// Order matters: groups first, then gid, then uid (root is lost after setuid).
guard setgroups(1, &gid) == 0 else { die("setgroups: \(String(cString: strerror(errno)))") }
guard setgid(gid) == 0 else { die("setgid: \(String(cString: strerror(errno)))") }
guard setuid(realUid) == 0 else { die("setuid: \(String(cString: strerror(errno)))") }

// Verify that the privilege drop is irreversible.
if setuid(0) == 0 || setgid(origGid) == 0 || setgid(20) == 0 { die("could not drop privileges irreversibly", 3) }
guard getgid() == gid, getegid() == gid, getuid() == realUid, geteuid() == realUid else { die("unexpected uid/gid after drop", 3) }

let argv = Array(CommandLine.arguments.dropFirst())
var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
cargs.append(nil)
execv(argv[0], &cargs)
die("execv \(argv[0]): \(String(cString: strerror(errno)))", 127)
