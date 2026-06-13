//
//  ClaudeTerminalLocator.swift
//  Hex
//
//  Finds the GUI app hosting a running `claude` CLI session so the summoned agent
//  window can send replies to it without the terminal being frontmost. We list all
//  processes via sysctl, pick the newest one named "claude", then walk its parent
//  chain (claude → shell → terminal emulator / IDE helper → app) until we hit a
//  process that NSWorkspace knows as a running application.
//

import AppKit
import Darwin
import HexCore

enum ClaudeTerminalLocator {
  private static let logger = HexLog.app

  /// Bundle-ID fragments of IDEs whose integrated terminals can host claude. These are
  /// deprioritized: an agent session in VS Code (e.g. the one driving Hex development)
  /// is usually newer than the terminal session the user actually wants to talk to.
  static let ideBundleFragments = ["vscode", "vscodium", "cursor", "windsurf"]

  /// The app hosting a running `claude` process, or nil if none. Prefers claudes in
  /// dedicated terminal apps over IDE-integrated ones; newest first within each group.
  @MainActor
  static func locate() -> NSRunningApplication? {
    let processes = allProcesses()
    // The native-installer binary reports its comm as "claude.exe"; npm installs as
    // "claude" — match the prefix. (p_comm is 16 chars, so long names truncate anyway.)
    let claudes = processes.values
      .filter { $0.name.hasPrefix("claude") }
      .sorted { $0.startTime > $1.startTime }
    guard !claudes.isEmpty else {
      logger.notice("No running claude process found")
      return nil
    }

    let appsByPID = Dictionary(
      NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) },
      uniquingKeysWith: { first, _ in first }
    )

    var ideFallback: NSRunningApplication?
    for claude in claudes {
      var pid = claude.ppid
      var hops = 0
      while pid > 1, hops < 16 {
        if let app = appsByPID[pid] {
          let bundle = (app.bundleIdentifier ?? "").lowercased()
          if ideBundleFragments.contains(where: { bundle.contains($0) }) {
            if ideFallback == nil { ideFallback = app }
          } else {
            logger.notice("Located claude session (pid \(claude.pid)) in \(app.localizedName ?? "?", privacy: .public)")
            return app
          }
          break
        }
        guard let parent = processes[pid] else { break }
        pid = parent.ppid
        hops += 1
      }
    }
    if let ide = ideFallback {
      logger.notice("Located claude session only in IDE host \(ide.localizedName ?? "?", privacy: .public)")
      return ide
    }
    logger.notice("Found claude process(es) but no owning GUI app")
    return nil
  }

  private struct ProcessInfoLite {
    var pid: pid_t
    var ppid: pid_t
    var name: String
    var startTime: TimeInterval
  }

  private static func allProcesses() -> [pid_t: ProcessInfoLite] {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var size = 0
    guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [:] }
    // Headroom in case the process table grows between the two calls.
    size += size / 8
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return [:] }

    let count = size / MemoryLayout<kinfo_proc>.stride
    var result: [pid_t: ProcessInfoLite] = [:]
    buffer.withUnsafeBytes { raw in
      let procs = raw.bindMemory(to: kinfo_proc.self)
      for i in 0 ..< count {
        var proc = procs[i]
        let name = withUnsafeBytes(of: &proc.kp_proc.p_comm) { bytes in
          String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let start = proc.kp_proc.p_starttime
        result[proc.kp_proc.p_pid] = ProcessInfoLite(
          pid: proc.kp_proc.p_pid,
          ppid: proc.kp_eproc.e_ppid,
          name: name,
          startTime: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000
        )
      }
    }
    return result
  }
}
