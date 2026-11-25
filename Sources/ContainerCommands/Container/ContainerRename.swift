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
    public struct ContainerRename: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "rename",
            abstract: "Rename a container"
        )

        @OptionGroup
        public var logOptions: Flags.Logging

        @Argument(help: "Current container ID or name")
        var container: String

        @Argument(help: "New container name")
        var newName: String

        public func run() async throws {
            guard ManagedContainer.nameValid(newName) else {
                throw ContainerizationError(
                    .invalidArgument, message: "container name \(newName) is not a valid container name")
            }
            let client = ContainerClient()
            try await client.rename(id: container, newName: newName)
            print(newName)
        }
    }
}
