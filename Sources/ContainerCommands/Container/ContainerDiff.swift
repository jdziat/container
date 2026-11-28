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
import Foundation

extension Application {
    public struct ContainerDiff: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "diff",
            abstract: "Inspect changes to files or directories on a container's filesystem"
        )

        @OptionGroup
        public var logOptions: Flags.Logging

        @Argument(help: "Container ID or name")
        var container: String

        public func run() async throws {
            let client = ContainerClient()
            let changes = try await client.diff(id: container)
            for change in changes {
                print("\(change.kind.rawValue) \(change.path)")
            }
        }
    }
}
