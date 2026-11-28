//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import ContainerPlugin
import ContainerizationExtras
import Foundation
import Logging

#if canImport(Darwin)
import Darwin
private let _kill = Darwin.kill
#elseif canImport(Glibc)
import Glibc
private let _kill = Glibc.kill
#endif

/// Runs a runtime plugin's `cleanup --root <bundle> --uuid <id>` subcommand, which releases
/// resources the plugin keeps outside the bundle
enum RuntimeCleanupHook {
    static let defaultTimeout: Duration = .seconds(60)

    /// Returns whether the plugin exited 0. Failures are logged, not thrown: a broken plugin must not block delete.
    /// - timeout: time bound for delete operation, will result in killing the plugin if it takes too long
    @discardableResult
    static func run(
        plugin: Plugin,
        root: URL,
        id: String,
        log: Logger,
        timeout: Duration = defaultTimeout
    ) async -> Bool {
        let metadata: Logger.Metadata = ["id": "\(id)", "plugin": "\(plugin.binaryURL)"]

        let (exits, exit) = AsyncStream<Int32>.makeStream()
        let process = Process()
        process.executableURL = plugin.binaryURL
        process.arguments = [
            "cleanup",
            "--root", root.path,
            "--uuid", id,
        ]
        process.terminationHandler = {
            exit.yield($0.terminationStatus)
            exit.finish()
        }

        do {
            try process.run()
        } catch {
            log.warning("failed to launch runtime cleanup hook", metadata: metadata.merging(["error": "\(error)"]) { $1 })
            return false
        }

        let launchIdentity = Self.processIdentity(pid: process.processIdentifier)

        let status: Int32
        do {
            status = try await Timeout.run(for: timeout) {
                for await status in exits {
                    return status
                }
                throw CancellationError()
            }
        } catch {
            log.warning("runtime cleanup hook timed out; sending SIGKILL", metadata: metadata.merging(["timeout": "\(timeout)"]) { $1 })
            await Self.forceKill(process, launchIdentity: launchIdentity)
            return false
        }

        guard status == 0 else {
            log.error("runtime cleanup hook failed or is not implemented", metadata: metadata.merging(["terminationStatus": "\(status)"]) { $1 })
            return false
        }
        return true
    }

    /// Kill the hook and any direct children.
    ///
    /// `Foundation.Process` does not put the child in its own process group, so
    /// `kill(-pid, …)` is unreliable. Kill direct children via `pkill -P`, then the
    /// plugin itself while `process.isRunning` still holds the unreaped child pid.
    /// When a launch-time start-time fingerprint is still readable and differs, skip
    /// SIGKILL (pid reuse). If the fingerprint cannot be re-read, fall back to isRunning.
    private static func forceKill(_ process: Process, launchIdentity: ProcessIdentity?) async {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        guard pid > 0 else { return }

        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-KILL", "-P", String(pid)]
        try? pkill.run()
        let deadline = ContinuousClock.now + .seconds(2)
        while pkill.isRunning && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if pkill.isRunning {
            pkill.terminate()
        }

        guard process.isRunning else { return }
        // Skip SIGKILL only when the re-read fingerprint proves a different process.
        // A nil re-read with isRunning still true means the unreaped child holds the pid.
        if let launchIdentity, let current = Self.processIdentity(pid: pid), current != launchIdentity {
            return
        }
        _ = _kill(pid, SIGKILL)
    }

    #if canImport(Darwin)
    private struct ProcessIdentity: Equatable {
        let startSec: Int64
        let startUsec: Int32
    }

    private static func processIdentity(pid: pid_t) -> ProcessIdentity? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        guard size >= MemoryLayout<kinfo_proc>.stride else { return nil }
        let start = info.kp_proc.p_starttime
        return ProcessIdentity(startSec: Int64(start.tv_sec), startUsec: start.tv_usec)
    }
    #else
    private struct ProcessIdentity: Equatable {}
    private static func processIdentity(pid: pid_t) -> ProcessIdentity? { nil }
    #endif
}
