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
import ContainerAPIClient
import ContainerResource
import ContainerizationError
import ContainerizationOS
import Foundation
import Logging

extension Application {
    public struct ContainerAttach: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "attach",
            abstract: "Attach local standard input, output, and error streams to a running container")

        @Flag(name: .shortAndLong, help: "Keep STDIN open (not supported for already-running init; use exec for a new interactive process)")
        var interactive = false

        @OptionGroup
        public var logOptions: Flags.Logging

        @Argument(help: "Container ID")
        var containerId: String

        public func run() async throws {
            let client = ContainerClient()
            let filters = ContainerListFilters().withoutPlugins([ResourcePluginValues.cluster])
            let container = try await client.findContainer(id: containerId, filters: filters)
            try ensureRunning(container: container)

            if interactive {
                log.warning(
                    "stdin attach to an already-running init process is not supported; streaming logs and waiting for exit. Use `container exec -it` for a new interactive process."
                )
            }

            let exitCode = try await Self.attachToRunning(client: client, id: container.id, log: log)
            throw ArgumentParser.ExitCode(exitCode)
        }

        /// Stream stdio logs from the current end and wait for the init process to exit.
        ///
        /// Init stdio is bound at bootstrap, so re-attaching stdin to a running init is not
        /// available. This matches the practical attach path for scripts that only need
        /// live output and an exit code (and for `container start -a` on an already-running
        /// container).
        static func attachToRunning(client: ContainerClient, id: String, log: Logger) async throws -> Int32 {
            let process = try await client.initProcess(id: id)
            let logHandles = try await client.logs(id: id)
            guard let stdioLog = logHandles.first else {
                throw ContainerizationError(
                    .notFound, message: "no stdio log handle available for container \(id)")
            }
            _ = try stdioLog.seekToEnd()
            setbuf(stdout, nil)

            let signals = AsyncSignalHandler.create(notify: [SIGTERM, SIGINT, SIGUSR1, SIGUSR2])
            return try await withThrowingTaskGroup(of: Int32?.self, returning: Int32.self) { group in
                _ = group.addTaskUnlessCancelled {
                    let code = try await process.wait()
                    return code
                }
                _ = group.addTaskUnlessCancelled {
                    try await ContainerLogs.followLogHandle(fh: stdioLog)
                    return nil
                }
                _ = group.addTaskUnlessCancelled {
                    for await sig in signals.signals {
                        do {
                            try await process.kill(sig)
                        } catch {
                            log.error(
                                "failed to send signal while attached",
                                metadata: [
                                    "signal": "\(sig)",
                                    "error": "\(error)",
                                ])
                        }
                    }
                    return nil
                }

                // Wait for the init exit code. Nil results from follow/signal tasks are
                // ignored so we keep waiting on process.wait(). cancelAll stops siblings
                // after the code is known (tail bytes still in the follow task may drop).
                while let result = try await group.next() {
                    if let code = result {
                        group.cancelAll()
                        return code
                    }
                }
                throw ContainerizationError(
                    .invalidState,
                    message: "attach ended without an exit code from container \(id)"
                )
            }
        }
    }
}
