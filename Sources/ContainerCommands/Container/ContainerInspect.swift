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
import ContainerizationError
import Foundation

extension Application {
    public struct ContainerInspect: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "inspect",
            abstract: "Display information about one or more containers")

        @OptionGroup
        public var logOptions: Flags.Logging

        @Option(name: .shortAndLong, help: "Format the output using a Go template, e.g. '{{.Name}}' or '{{json .}}'")
        var format: String?

        @Argument(help: "Container IDs to inspect")
        var containerIds: [String]

        public func run() async throws {
            let client = ContainerClient()
            // Prefer exact Id over Name (same policy as ContainerLookup) so a Name that
            // collides with another container's Id cannot silently inspect the wrong one.
            let listed = try await client.list()
            var byId: [String: ContainerSnapshot] = [:]
            var byName: [String: [ContainerSnapshot]] = [:]
            for snap in listed {
                byId[snap.id] = snap
                let name = snap.configuration.name
                if !name.isEmpty {
                    byName[name, default: []].append(snap)
                }
            }
            var containers: [ContainerSnapshot] = []
            var missing: [String] = []
            var ambiguous: [String] = []
            var seenIds = Set<String>()
            for key in containerIds {
                if let snap = byId[key] {
                    if seenIds.insert(snap.id).inserted {
                        containers.append(snap)
                    }
                    continue
                }
                let named = byName[key] ?? []
                if named.isEmpty {
                    missing.append(key)
                } else if named.count > 1 {
                    ambiguous.append(key)
                } else if seenIds.insert(named[0].id).inserted {
                    containers.append(named[0])
                }
            }
            if !ambiguous.isEmpty {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "container name is ambiguous: \(ambiguous.joined(separator: ", "))"
                )
            }
            if !missing.isEmpty {
                throw ContainerizationError(
                    .notFound,
                    message: "container not found: \(missing.joined(separator: ", "))"
                )
            }

            let managed = containers.map { ManagedContainer($0) }
            if let format {
                guard GoTemplate.isTemplate(format) else {
                    throw ContainerizationError(.invalidArgument, message: "--format expects a Go template such as '{{.Name}}'")
                }
                try Output.renderTemplate(format, payload: managed)
                return
            }
            try Output.emit(Output.renderJSON(managed, options: .pretty))
        }
    }
}
