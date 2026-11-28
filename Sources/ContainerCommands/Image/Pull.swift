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

extension Application {
    /// Docker-style top-level alias for `image pull`.
    public struct Pull: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "pull",
            abstract: "Pull an image"
        )

        @OptionGroup
        var registry: Flags.Registry

        @OptionGroup
        var progressFlags: Flags.Progress

        @OptionGroup
        var imageFetchFlags: Flags.ImageFetch

        @Option(name: .shortAndLong, help: "Limit the pull to the specified architecture")
        var arch: String?

        @Option(help: "Limit the pull to the specified OS")
        var os: String?

        @Option(
            help:
                "Limit the pull to the specified platform (format: os/arch[/variant], takes precedence over --os and --arch) [environment: CONTAINER_DEFAULT_PLATFORM]"
        )
        var platform: String?

        @OptionGroup
        public var logOptions: Flags.Logging

        @Argument var reference: String

        public mutating func run() async throws {
            var pull = ImagePull()
            pull.registry = registry
            pull.progressFlags = progressFlags
            pull.imageFetchFlags = imageFetchFlags
            pull.arch = arch
            pull.os = os
            pull.platform = platform
            pull.logOptions = logOptions
            pull.reference = reference
            try await pull.run()
        }
    }
}
