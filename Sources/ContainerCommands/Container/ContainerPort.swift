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
    public struct ContainerPort: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "port",
            abstract: "List the published ports of a container")

        @OptionGroup
        public var logOptions: Flags.Logging

        @Argument(help: "Container ID")
        var containerId: String

        @Argument(help: "Only show mappings for this container port, as <port> or <port>/<proto>")
        var privatePort: String?

        /// A container port, optionally restricted to a protocol, to filter published ports by.
        struct PortFilter: Equatable {
            let port: UInt16
            let proto: PublishProtocol?

            init(parsing value: String) throws {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    throw ContainerizationError(.invalidArgument, message: "invalid container port \"\(value)\": expected <port> or <port>/<proto>")
                }
                let parts = trimmed.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
                guard let portToken = parts.first, let port = UInt16(portToken) else {
                    throw ContainerizationError(.invalidArgument, message: "invalid container port \"\(value)\": expected <port> or <port>/<proto>")
                }
                self.port = port
                if parts.count == 2 {
                    guard let proto = PublishProtocol(String(parts[1])) else {
                        throw ContainerizationError(.invalidArgument, message: "invalid protocol \"\(parts[1])\": expected tcp or udp")
                    }
                    self.proto = proto
                } else {
                    self.proto = nil
                }
            }
        }

        public func validate() throws {
            if let privatePort {
                _ = try PortFilter(parsing: privatePort)
            }
        }

        public func run() async throws {
            let client = ContainerClient()
            let filters = ContainerListFilters().withoutPlugins([ResourcePluginValues.cluster])
            let container = try await client.findContainer(id: containerId, filters: filters)
            let filter = try privatePort.map { try PortFilter(parsing: $0) }

            let lines = Self.formatPorts(container.configuration.publishedPorts, filter: filter)
            if let privatePort, lines.isEmpty {
                throw ContainerizationError(
                    .notFound,
                    message: "no public port \"\(privatePort)\" published for container \(container.id)"
                )
            }
            for line in lines {
                print(line)
            }
        }

        /// Renders each published port as `<host address>:<host port>:<container port>/<proto>`,
        /// expanding port ranges into one line per port.
        static func formatPorts(_ ports: [PublishPort], filter: PortFilter? = nil) -> [String] {
            var lines: [String] = []
            for published in ports {
                if let proto = filter?.proto, proto != published.proto {
                    continue
                }
                for offset in 0..<published.count {
                    let containerBase = UInt32(published.containerPort)
                    let hostBase = UInt32(published.hostPort)
                    let containerWide = containerBase + UInt32(offset)
                    let hostWide = hostBase + UInt32(offset)
                    guard containerWide <= UInt32(UInt16.max), hostWide <= UInt32(UInt16.max) else {
                        continue
                    }
                    let containerPort = UInt16(containerWide)
                    if let filter, filter.port != containerPort {
                        continue
                    }
                    let hostPort = UInt16(hostWide)
                    lines.append("\(published.hostAddress):\(hostPort):\(containerPort)/\(published.proto.rawValue)")
                }
            }
            return lines
        }
    }
}
