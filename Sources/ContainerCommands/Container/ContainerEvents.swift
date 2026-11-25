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
    public struct ContainerEvents: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "events",
            abstract: "Stream container lifecycle events"
        )

        @OptionGroup
        public var logOptions: Flags.Logging

        public func run() async throws {
            let client = ContainerClient()
            var since: UInt64 = 0
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            while true {
                let batch = try await client.events(since: since)
                for event in batch {
                    since = max(since, event.id)
                    let data = try encoder.encode(event)
                    if let line = String(data: data, encoding: .utf8) {
                        print(line)
                        fflush(stdout)
                    }
                }
            }
        }
    }
}
