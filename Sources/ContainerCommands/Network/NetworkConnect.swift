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
import Foundation

extension Application.NetworkCommand {
    public struct NetworkConnect: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "connect",
            abstract: "Connect a container to a network"
        )

        @OptionGroup
        public var logOptions: Flags.Logging

        @Option(name: .long, help: "Add network-scoped alias for the container")
        var alias: [String] = []

        @Flag(
            name: .long,
            help:
                "Accepted for compatibility; running containers are restarted automatically so the attachment takes effect (interim toward true NIC hotplug)"
        )
        var restart = false

        @Argument(help: "Network name")
        var network: String

        @Argument(help: "Container ID or name")
        var container: String

        public func run() async throws {
            let client = ContainerClient()
            // F4 interim: always request restart; service auto-restarts running containers.
            try await client.networkConnect(
                id: container, network: network, aliases: alias, restartIfRunning: true)
        }
    }

    public struct NetworkDisconnect: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "disconnect",
            abstract: "Disconnect a container from a network"
        )

        @OptionGroup
        public var logOptions: Flags.Logging

        @Flag(
            name: .long,
            help:
                "Accepted for compatibility; running containers are restarted automatically so the detachment takes effect (interim toward true NIC hotplug)"
        )
        var restart = false

        @Flag(name: .long, help: "Do not error if the container is not connected")
        var force = false

        @Argument(help: "Network name")
        var network: String

        @Argument(help: "Container ID or name")
        var container: String

        public func run() async throws {
            let client = ContainerClient()
            // F4 interim: always request restart; service auto-restarts running containers.
            try await client.networkDisconnect(
                id: container, network: network, restartIfRunning: true, force: force)
        }
    }
}
