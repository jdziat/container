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
    /// Docker-style top-level alias for `registry login`.
    public struct Login: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "login",
            abstract: "Log in to a registry"
        )

        @OptionGroup
        var registry: Flags.Registry

        @Flag(help: "Take the password from stdin")
        var passwordStdin: Bool = false

        @Option(name: .shortAndLong, help: "Registry user name")
        var username: String = ""

        @OptionGroup
        public var logOptions: Flags.Logging

        @Argument(help: "Registry server name")
        var server: String

        public func run() async throws {
            var login = RegistryLogin()
            login.registry = registry
            login.passwordStdin = passwordStdin
            login.username = username
            login.logOptions = logOptions
            login.server = server
            try await login.run()
        }
    }
}
