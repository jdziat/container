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
import ContainerizationExtras
import Foundation
import SwiftProtobuf

extension Application {
    public struct ContainerList: AsyncLoggableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List running containers",
            aliases: ["ls", "ps"])

        @Flag(name: .shortAndLong, help: "Include containers that are not running")
        var all = false

        @Option(name: .long, help: "Format of the output: json, table, yaml, toml, or a Go template like '{{.ID}}'")
        var format: FormatArgument = .table

        @Option(name: [.short, .customLong("filter")], help: "Filter output (status=, name=, id=, label=key[=value], ancestor=). Repeatable; all must match.")
        var filter: [String] = []

        @Flag(name: .shortAndLong, help: "Only output the container ID")
        var quiet = false

        @OptionGroup
        public var logOptions: Flags.Logging

        public init() {}

        public func run() async throws {
            let client = ContainerClient()

            let parsed = try ContainerFilter.parse(filter)
            // An explicit status filter overrides the implicit "running only" default.
            let showAll = self.all || parsed.status != nil
            let filters = ContainerListFilters(status: showAll ? nil : .running).withoutPlugins([ResourcePluginValues.machine, ResourcePluginValues.cluster])
            let containers = try await client.list(filters: filters)
            let items = containers.map { ManagedContainer($0) }.filter { parsed.matches($0) }
            try format.render(payload: items, display: items, quiet: quiet)
        }
    }
}

/// Docker-style `--filter key=value` for `ps`.
struct ContainerFilter {
    var status: RuntimeStatus?
    var names: [String] = []
    var ids: [String] = []
    var ancestors: [String] = []
    var labels: [(key: String, value: String?)] = []

    static func parse(_ raw: [String]) throws -> ContainerFilter {
        var result = ContainerFilter()
        for item in raw {
            let parts = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, !parts[1].isEmpty || parts[0] == "label" else {
                throw ValidationError("invalid filter '\(item)': expected key=value")
            }
            switch parts[0] {
            case "status":
                // Docker says "exited"/"created"; this project says "stopped".
                let value = parts[1] == "exited" || parts[1] == "created" ? "stopped" : parts[1]
                guard let status = RuntimeStatus(rawValue: value) else {
                    throw ValidationError("invalid status filter '\(parts[1])'")
                }
                result.status = status
            case "name": result.names.append(parts[1])
            case "id": result.ids.append(parts[1])
            case "ancestor": result.ancestors.append(parts[1])
            case "label":
                let kv = parts[1].split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                guard let key = kv.first, !key.isEmpty else {
                    throw ValidationError("invalid filter 'label=\(parts[1])': the label key is empty")
                }
                result.labels.append((key, kv.count > 1 ? kv[1] : nil))
            default:
                throw ValidationError("unsupported filter '\(parts[0])' (supported: status, name, id, label, ancestor)")
            }
        }
        return result
    }

    func matches(_ c: ManagedContainer) -> Bool {
        if let status, c.status.state != status { return false }
        if !names.isEmpty, !names.contains(where: { c.name.contains($0) }) { return false }
        if !ids.isEmpty, !ids.contains(where: { c.id.hasPrefix($0) }) { return false }
        if !ancestors.isEmpty, !ancestors.contains(where: { c.configuration.image.reference.contains($0) }) { return false }
        for (key, value) in labels {
            guard let actual = c.configuration.labels[key] else { return false }
            if let value, actual != value { return false }
        }
        return true
    }
}
