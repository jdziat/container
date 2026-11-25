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
import ContainerPersistence
import ContainerResource
import Containerization
import ContainerizationError
import ContainerizationOCI
import Foundation

extension Application {
    public struct ImageHistory: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "history",
            abstract: "Show the history of an image"
        )

        @OptionGroup
        public var logOptions: Flags.Logging

        @Option(name: .long, help: "Format of the output")
        var format: ListFormat = .table

        @Flag(name: [.customLong("human"), .customShort("H")], inversion: .prefixedNo, help: "Print sizes and dates in human-readable format")
        var human: Bool = true

        @Argument(help: "Image reference")
        var image: String

        public func run() async throws {
            let containerSystemConfig: ContainerSystemConfig = try await ClientHealthCheck.loadContainerSystemConfig()
            let result = try await ClientImage.get(names: [image], containerSystemConfig: containerSystemConfig)
            if !result.error.isEmpty {
                throw ContainerizationError(.notFound, message: "image not found: \(image)")
            }
            guard let clientImage = result.images.first else {
                throw ContainerizationError(.notFound, message: "image not found: \(image)")
            }

            let platform = try await Self.resolvePlatform(for: clientImage)
            let config = try await clientImage.config(for: platform)
            let manifest = try await clientImage.manifest(for: platform)
            let rows = Self.historyRows(
                reference: clientImage.reference,
                history: config.history ?? [],
                layers: manifest.layers,
                humanReadable: human
            )

            try Output.render(payload: rows, format: format, jsonOptions: .pretty) {
                Self.table(rows)
            }
        }

        private static func resolvePlatform(for image: ClientImage) async throws -> Platform {
            let index = try await image.index()
            if let match = index.manifests.first(where: { $0.platform == Platform.current })?.platform {
                return match
            }
            if let first = index.manifests.first?.platform {
                return first
            }
            return Platform.current
        }

        struct Row: Codable, Sendable {
            let image: String
            let created: String
            let createdBy: String
            let size: String
            let comment: String
        }

        static func historyRows(
            reference: String,
            history: [History],
            layers: [Descriptor],
            humanReadable: Bool
        ) -> [Row] {
            // Pair non-empty history entries with layers from the bottom up.
            var layerSizes = layers.map(\.size)
            var sized: [(History, UInt64)] = []
            for entry in history {
                let empty = entry.emptyLayer == true
                if empty {
                    sized.append((entry, 0))
                } else if !layerSizes.isEmpty {
                    sized.append((entry, UInt64(layerSizes.removeFirst())))
                } else {
                    sized.append((entry, 0))
                }
            }
            // Docker prints newest first.
            return sized.reversed().map { entry, size in
                Row(
                    image: shortID(reference),
                    created: formatCreated(entry.created, humanReadable: humanReadable),
                    createdBy: truncate(entry.createdBy ?? "", limit: 45),
                    size: formatSize(size, humanReadable: humanReadable),
                    comment: entry.comment ?? ""
                )
            }
        }

        private static func table(_ rows: [Row]) -> String {
            var tableRows: [[String]] = [["IMAGE", "CREATED", "CREATED BY", "SIZE", "COMMENT"]]
            for row in rows {
                tableRows.append([row.image, row.created, row.createdBy, row.size, row.comment])
            }
            return TableOutput(rows: tableRows).format()
        }

        private static func shortID(_ reference: String) -> String {
            if reference.hasPrefix("sha256:"), reference.count > 19 {
                return String(reference.prefix(19))
            }
            // Prefer the name:tag tail when present.
            if let slash = reference.lastIndex(of: "/") {
                return String(reference[reference.index(after: slash)...])
            }
            return reference
        }

        private static func formatCreated(_ value: String?, humanReadable: Bool) -> String {
            guard let value, !value.isEmpty else { return "" }
            guard humanReadable else { return value }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let date = formatter.date(from: value) ?? {
                formatter.formatOptions = [.withInternetDateTime]
                return formatter.date(from: value)
            }()
            guard let date else { return value }
            let rel = RelativeDateTimeFormatter()
            rel.unitsStyle = .full
            return rel.localizedString(for: date, relativeTo: Date())
        }

        private static func formatSize(_ bytes: UInt64, humanReadable: Bool) -> String {
            if !humanReadable {
                return "\(bytes)"
            }
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return formatter.string(fromByteCount: Int64(bytes))
        }

        private static func truncate(_ value: String, limit: Int) -> String {
            guard value.count > limit else { return value }
            return String(value.prefix(limit - 3)) + "..."
        }
    }
}
