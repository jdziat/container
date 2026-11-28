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

import ContainerTestSupport
import Darwin
import Foundation
import Testing

/// Concurrent lifecycle tests for `container run` / `start` / `exec`.
@Suite
struct TestCLIRunLifecycle {
    @Test func testRunFailureCleanup() async throws {
        try await ContainerFixture.with { f in
            let image = WarmupImage.alpine320.rawValue
            let name = "\(f.testID)-c"

            // First attempt with an invalid user — must fail.
            let failResult = try f.run([
                "run", "--rm", "--name", name, "-d",
                "--user", "u-\(f.testID)",  // non-numeric, guaranteed not to exist in /etc/passwd
                image, "sleep", "infinity",
            ])
            #expect(failResult.status != 0, "expected run to fail with invalid user")

            // Second attempt with the same name and no user — must succeed.
            try await f.withContainer(image: image) { containerName in
                _ = try f.doExec(containerName, cmd: ["date"])
            }
        }
    }

    @Test func testStartIdempotent() async throws {
        try await ContainerFixture.with { f in
            let image = WarmupImage.alpine320.rawValue
            try await f.withContainer(image: image) { name in
                let result = try f.run(["start", name])
                #expect(result.status == 0, "expected start to succeed on already running container")
                #expect(
                    result.output.trimmingCharacters(in: .whitespacesAndNewlines) == name,
                    "expected output to be container name")
                _ = try f.inspectContainer(name)
            }
        }
    }

    @Test func testStartAttachOnAlreadyRunningWaitsForExit() async throws {
        try await ContainerFixture.with { f in
            let image = WarmupImage.alpine320.rawValue
            let name = "\(f.testID)-c"
            f.addCleanup {
                try? f.doStop(name)
                try f.doRemoveIfExists(name, force: true, ignoreFailure: true)
            }
            // Block until /tmp/done appears so we control exit after attach is live.
            try f.run([
                "run", "--name", name, "-d", image,
                "sh", "-c", "while [ ! -f /tmp/done ]; do sleep 0.1; done; exit 7",
            ]).check()
            try await f.waitForContainerRunning(name)
            let attach = Task { try f.run(["start", "-a", name]) }
            // Wait for the container CLI child (not the Swift test runner) to show argv,
            // then settle past findContainer + attachToRunning before releasing the guest.
            try await Self.waitForContainerCLIAttach(name: name)
            try await Task.sleep(for: .seconds(1))
            _ = try f.doExec(name, cmd: ["sh", "-c", "test -d /proc/1 && touch /tmp/done"])
            let result = try await attach.value
            #expect(
                result.status == 7,
                "start -a on a running container should attach and return exit 7, got \(result.status)")
        }
    }

    /// Poll until a host process argv looks like the `container` CLI `start -a <name>`.
    ///
    /// Each `ps` probe is itself time-bounded: under heavy parallel integration load,
    /// an unbounded `waitUntilExit()` on `/bin/ps` has been observed to hang the suite.
    private static func waitForContainerCLIAttach(name: String, timeout: Duration = .seconds(30)) async throws {
        let needle = "start -a \(name)"
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let output = try await Self.processListSnapshot(timeout: .seconds(2)) {
                let hit = output.split(whereSeparator: \.isNewline).contains { line in
                    let s = String(line)
                    guard s.contains(needle) else { return false }
                    // Require a container CLI path/argv form; ignore this `ps` probe and the test binary.
                    let looksLikeCLI = s.contains("/container ") || s.hasPrefix("container ") || s.contains("container start")
                    return looksLikeCLI && !s.contains("ps -axo")
                }
                if hit { return }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw CommandError.executionFailed("timed out waiting for container CLI start -a \(name)")
    }

    /// Best-effort `ps -axo command=` with a hard kill if the probe stalls.
    ///
    /// Writes to a temp file rather than a `Pipe` so a large process list cannot
    /// deadlock `waitUntilExit` on a full pipe buffer (the failure mode that hung
    /// this suite under concurrent integration load).
    private static func processListSnapshot(timeout: Duration) async throws -> String? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ps-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: tmp) }

        return try await withThrowingTaskGroup(of: String?.self) { group in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/ps")
            process.arguments = ["-axo", "command="]
            let out = try FileHandle(forWritingTo: tmp)
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            try process.run()

            group.addTask {
                process.waitUntilExit()
                try? out.close()
                return try? String(contentsOf: tmp, encoding: .utf8)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                if process.isRunning {
                    process.terminate()
                    try await Task.sleep(for: .milliseconds(200))
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
                return nil
            }

            let first = try await group.next()!
            group.cancelAll()
            _ = try? await group.next()
            return first
        }
    }

    @Test func testRunInvalidExecutable() async throws {
        try await ContainerFixture.with { f in
            let image = WarmupImage.alpine320.rawValue
            let name = "\(f.testID)-c"
            f.addCleanup { try f.doRemoveIfExists(name, force: true, ignoreFailure: true) }
            let result = try f.run(["run", "--rm", "--name", name, "-d", image, "foobarbaz"])
            #expect(result.status != 0, "running invalid executable must fail, not hang")
        }
    }

    @Test func testExecInvalidExecutable() async throws {
        try await ContainerFixture.with { f in
            let image = WarmupImage.alpine320.rawValue
            try await f.withContainer(image: image) { name in
                let result = try f.run(["exec", name, "foobarbaz"])
                #expect(result.status != 0, "executing invalid executable must fail, not hang")
            }
        }
    }

    @Test func testSSHForwarding() async throws {
        try await ContainerFixture.with { f in
            let image = WarmupImage.alpine320.rawValue

            let socketPath = try f.makeFakeSSHAgentSocket()

            // Run container with --ssh; SSH_AUTH_SOCK must be in the CLI process environment.
            let name = "\(f.testID)-c"
            f.addCleanup { try? f.doStop(name) }
            try f.run(
                ["run", "--rm", "--name", name, "-d", "--ssh", image, "sleep", "infinity"],
                env: ["SSH_AUTH_SOCK": socketPath]
            ).check()
            try await f.waitForContainerRunning(name)

            let sshSockValue = try f.doExec(name, cmd: ["sh", "-c", "echo $SSH_AUTH_SOCK"])
            #expect(
                sshSockValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    == "/var/host-services/ssh-auth.sock",
                "expected SSH_AUTH_SOCK to point to guest socket path")

            let socketCheck = try f.doExec(
                name, cmd: ["sh", "-c", "[ -S /var/host-services/ssh-auth.sock ] && echo exists || echo missing"])
            #expect(
                socketCheck.trimmingCharacters(in: .whitespacesAndNewlines) == "exists",
                "expected forwarded SSH socket to exist in container")

            try f.doStop(name)
        }
    }
}
