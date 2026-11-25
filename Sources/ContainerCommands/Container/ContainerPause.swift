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

extension Application {
    public struct ContainerPause: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "pause",
            abstract: "Pause one or more running containers"
        )

        @OptionGroup
        public var logOptions: Flags.Logging

        @Argument(help: "Containers to pause (ID or name)")
        var containers: [String]

        public func run() async throws {
            let client = ContainerClient()
            for id in containers {
                try await client.pause(id: id)
                print(id)
            }
        }
    }

    public struct ContainerUnpause: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "unpause",
            abstract: "Unpause one or more paused containers"
        )

        @OptionGroup
        public var logOptions: Flags.Logging

        @Argument(help: "Containers to unpause (ID or name)")
        var containers: [String]

        public func run() async throws {
            let client = ContainerClient()
            for id in containers {
                try await client.unpause(id: id)
                print(id)
            }
        }
    }
}
