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
    public struct ContainerWait: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "wait",
            abstract: "Block until one or more containers stop, then print their exit codes")

        @OptionGroup
        public var logOptions: Flags.Logging

        @Argument(help: "Container IDs")
        var containerIds: [String]

        public func validate() throws {
            if containerIds.isEmpty {
                throw ContainerizationError(.invalidArgument, message: "no containers specified")
            }
        }

        public mutating func run() async throws {
            let client = ContainerClient()

            // Cluster nodes are managed by `container cluster`, so naming one reports it as not found.
            let filters = ContainerListFilters().withoutPlugins([ResourcePluginValues.cluster])
            // `found` is already in the caller's id order.
            let (found, notFoundErrors) = try await client.findContainers(named: containerIds, filters: filters)

            var errors: [any Error] = notFoundErrors
            for container in found {
                do {
                    // Like `docker wait`, attempt wait even if the container already exited.
                    let exitCode = try await client.initProcess(id: container.id).wait()
                    print(exitCode)
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
