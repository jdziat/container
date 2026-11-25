//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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
    /// Docker-style top-level alias for `image list`.
    ///
    /// Parent-command aliases on `ImageCommand` would require `container images ls`;
    /// this thin command makes `container images` list images directly.
    public struct Images: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "images",
            abstract: "List images"
        )

        @Option(name: .long, help: "Format of the output")
        var format: FormatArgument = .table

        @Flag(name: .shortAndLong, help: "Only output the image name")
        var quiet = false

        @Flag(name: .shortAndLong, help: "Verbose output")
        var verbose = false

        @OptionGroup
        public var logOptions: Flags.Logging

        public mutating func run() async throws {
            var list = ImageList()
            list.format = format
            list.quiet = quiet
            list.verbose = verbose
            list.logOptions = logOptions
            try await list.run()
        }
    }
}
