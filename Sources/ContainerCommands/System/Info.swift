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

extension Application {
    /// Docker-style top-level alias for `system status`.
    public struct Info: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "info",
            abstract: "Show system status (Docker-compatible alias for `system status`)"
        )

        @Option(name: .shortAndLong, help: "Launchd prefix for services")
        var prefix: String = "com.apple.container."

        @Option(name: .long, help: "Format of the output")
        var format: ListFormat = .table

        @OptionGroup
        public var logOptions: Flags.Logging

        public func run() async throws {
            // Parse through ArgumentParser so every @Option default is initialized;
            // constructing SystemStatus() directly leaves them unreadable.
            var status = try SystemStatus.parse(["--prefix", prefix, "--format", format.rawValue])
            status.logOptions = logOptions
            try await status.run()
        }
    }
}
