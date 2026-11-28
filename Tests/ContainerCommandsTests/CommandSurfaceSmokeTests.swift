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

import ArgumentParser
import Foundation
import Testing

@testable import ContainerCommands

/// Every command must at least parse and construct. This is the regression net for the
/// two bugs the 2026-11-24 audit found by hand: `container info` (uninitialized `@Option`s
/// read at run time) and `compose logs` (duplicate `-f` short flag), neither of which a
/// compile or a unit test of the command body can see.
struct CommandSurfaceSmokeTests {
    private static func leaves(_ type: any ParsableCommand.Type, path: [String] = []) -> [[String]] {
        let name = type.configuration.commandName ?? String(describing: type).lowercased()
        let here = path + [name]
        let children = type.configuration.subcommands + type.configuration.groupedSubcommands.flatMap(\.subcommands)
        guard !children.isEmpty else { return [here] }
        return children.flatMap { leaves($0, path: here) }
    }

    @Test func everyCommandValidatesItsOwnArgumentDefinition() {
        // `helpMessage` forces ArgumentParser to build and validate the full argument set;
        // a duplicate short name or similar fails here with "Validation failed".
        let all = Self.leaves(Application.self)
        #expect(all.count > 40, "command tree unexpectedly small: \(all.count)")
        for path in all {
            var type: any ParsableCommand.Type = Application.self
            for component in path.dropFirst() {
                let children = type.configuration.subcommands + type.configuration.groupedSubcommands.flatMap(\.subcommands)
                guard let next = children.first(where: { ($0.configuration.commandName ?? "") == component }) else { break }
                type = next
            }
            let help = type.helpMessage()
            #expect(!help.contains("Validation failed"), "\(path.joined(separator: " ")): \(help)")
        }
    }

    @Test func infoAliasParsesWithEveryOptionInitialized() throws {
        let status = try Application.SystemStatus.parse(["--prefix", "com.apple.container.", "--format", "json"])
        #expect(status.format == .json)
        let info = try Application.Info.parse(["--format", "json"])
        #expect(info.format == .json)
        #expect(try Application.Info.parse([]).prefix == "com.apple.container.")
    }

    /// The real regression test for `container info`. The original bug was in `run()`:
    /// it built `SystemStatus()` directly and then read `@Option`s that were never decoded.
    /// ArgumentParser reports that by printing "Can't read a value from a parsable argument
    /// definition" and exiting 1, which is indistinguishable by exit code from a healthy
    /// "service not registered" exit, and invisible to a parse-only test. So this runs the
    /// body in a child process and asserts on its captured output.
    @Test func infoRunDoesNotTripUninitializedArgumentRead() async throws {
        let result = try await #require(
            processExitsWith: .failure, observing: [\.standardOutputContent, \.standardErrorContent]
        ) {
            var info = try Application.Info.parse([])
            do { try await info.run() } catch {}
            exit(42)  // run() returned or threw normally; any exit satisfies the outer condition
        }
        let output = String(decoding: result.standardOutputContent + result.standardErrorContent, as: UTF8.self)
        #expect(
            !output.contains("Can't read a value"),
            "container info read an uninitialized @Option:\n\(output)")
    }

    @Test func dockerFlagsParseOnRun() throws {
        let run = try Application.ContainerRun.parse([
            "--add-host", "db:10.0.0.1", "--sysctl", "net.ipv4.ip_forward=1", "--stop-signal", "SIGINT",
            "--privileged", "--security-opt", "seccomp=unconfined", "--pids-limit", "10", "--gpus", "all",
            "alpine:3.20", "true",
        ])
        #expect(run.managementFlags.addHosts == ["db:10.0.0.1"])
        #expect(run.managementFlags.privileged)
    }

    @Test func formatArgumentAcceptsNamedFormatsAndTemplatesOnly() {
        #expect(FormatArgument(argument: "json") != nil)
        #expect(FormatArgument(argument: "{{.Names}}") != nil)
        #expect(FormatArgument(argument: "xml") == nil)
        #expect(FormatArgument(argument: "{{.Names}}")?.template == "{{.Names}}")
        #expect(FormatArgument(argument: "table")?.template == nil)
    }

    @Test func psFilterParsing() throws {
        let parsed = try ContainerFilter.parse(["status=exited", "name=web", "label=env=prod", "label=flag"])
        #expect(parsed.status == .stopped, "docker's 'exited' maps to this project's 'stopped'")
        #expect(parsed.names == ["web"])
        #expect(parsed.labels.count == 2)
        #expect(throws: (any Error).self) { try ContainerFilter.parse(["bogus=1"]) }
        #expect(throws: (any Error).self) { try ContainerFilter.parse(["status=wat"]) }
        #expect(throws: (any Error).self) { try ContainerFilter.parse(["noequals"]) }
        // `label=` with an empty key used to index an empty array and trap.
        #expect(throws: (any Error).self) { try ContainerFilter.parse(["label="]) }
        #expect(throws: (any Error).self) { try ContainerFilter.parse(["label==x"]) }
    }
}
