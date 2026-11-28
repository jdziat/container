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
    public struct ContainerUpdate: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "update",
            abstract: "Update configuration of one or more containers"
        )

        @OptionGroup
        public var logOptions: Flags.Logging

        @Option(name: .long, help: "Number of CPUs")
        var cpus: Int64?

        @Option(name: .customLong("memory"), help: "Memory limit (e.g. 1G, 512m)")
        var memory: String?

        @Option(name: .long, help: "Restart policy (no|on-failure[:max]|always|unless-stopped)")
        var restart: String?

        @Argument(help: "Containers to update (ID or name)")
        var containers: [String]

        public func run() async throws {
            guard cpus != nil || memory != nil || restart != nil else {
                throw ContainerizationError(
                    .invalidArgument, message: "at least one of --cpus, --memory, or --restart is required")
            }
            if let cpus {
                try ContainerConfiguration.Resources.validate(cpus: cpus)
            }
            var memoryBytes: UInt64?
            if let memory {
                let measurement = try Measurement.parse(parsing: memory)
                memoryBytes = UInt64(measurement.converted(to: .bytes).value)
                try ContainerConfiguration.Resources.validate(memoryInBytes: memoryBytes!)
            }
            var policy: RestartPolicy?
            var maxRetries: UInt64?
            if let restart {
                let parsed = try RestartPolicy.parseDetailed(restart)
                policy = parsed.policy
                maxRetries = parsed.maximumRetryCount
            }

            let client = ContainerClient()
            for id in containers {
                try await client.update(
                    id: id,
                    cpus: cpus.map(Int.init),
                    memoryInBytes: memoryBytes,
                    restartPolicy: policy,
                    restartMaxRetries: maxRetries
                )
                print(id)
            }
        }
    }
}
