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
import Foundation

extension Application {
    public struct ContainerRestart: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "restart",
            abstract: "Restart one or more containers")

        @Flag(name: .shortAndLong, help: "Restart all running containers")
        var all = false

        @Option(name: .shortAndLong, help: "Seconds to wait before killing the containers on stop")
        var time: Int32 = 5

        @OptionGroup
        public var logOptions: Flags.Logging

        @Argument(help: "Container IDs")
        var containerIds: [String] = []

        public func validate() throws {
            if containerIds.isEmpty && !all {
                throw ContainerizationError(.invalidArgument, message: "no containers specified and --all not supplied")
            }
            if !containerIds.isEmpty && all {
                throw ContainerizationError(
                    .invalidArgument, message: "explicitly supplied container IDs conflict with the --all flag")
            }
        }

        public mutating func run() async throws {
            let client = ContainerClient()
            var errors: [any Error] = []
            let containers: [String]
            if self.all {
                let filters = ContainerListFilters().withoutPlugins([ResourcePluginValues.machine, ResourcePluginValues.cluster])
                containers = try await client.list(filters: filters).map(\.id)
            } else {
                let filters = ContainerListFilters().withoutPlugins([ResourcePluginValues.cluster])
                let (found, notFoundErrors) = try await client.findContainers(named: containerIds, filters: filters)
                containers = found.map(\.id)
                errors += notFoundErrors
            }

            let stopOptions = ContainerStopOptions(timeoutInSeconds: self.time, signal: nil)
            for id in containers {
                do {
                    try await client.stop(id: id, opts: stopOptions)
                    let container = try await client.get(id: id)
                    let io = try ProcessIO.create(
                        tty: container.configuration.initProcess.terminal,
                        interactive: false,
                        detach: true
                    )
                    defer { try? io.close() }
                    var env: [String: String] = [:]
                    if let sshAuthSock = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] {
                        env["SSH_AUTH_SOCK"] = sshAuthSock
                    }
                    let process = try await client.bootstrap(id: id, stdio: io.stdio, dynamicEnv: env)
                    try await process.start()
                    try io.closeAfterStart()
                    print(id)
                } catch {
                    errors.append(error)
                }
            }
            if !errors.isEmpty {
                throw AggregateError(errors)
            }
        }
    }
}
