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
import ContainerResource

/// `--format` value: a named format (`json|table|yaml|toml`) or a Docker-style Go
/// template such as `'{{.Names}}\t{{.Status}}'`.
public struct FormatArgument: ExpressibleByArgument, Sendable {
    public let raw: String

    public init?(argument: String) {
        guard GoTemplate.isTemplate(argument) || ListFormat(rawValue: argument) != nil else { return nil }
        self.raw = argument
    }

    public init(_ format: ListFormat) { self.raw = format.rawValue }

    public static let table = FormatArgument(.table)

    public static var allValueStrings: [String] { ListFormat.allCases.map(\.rawValue) + ["'{{.Field}}' template"] }

    public var template: String? { GoTemplate.isTemplate(raw) ? raw : nil }
    public var listFormat: ListFormat { ListFormat(rawValue: raw) ?? .table }

    /// Render a list, honoring templates, named formats and `--quiet`.
    public func render<J: Encodable, D: ListDisplayable>(payload: J, display: [D], quiet: Bool) throws {
        if let template {
            try Output.renderTemplate(template, payload: payload)
        } else {
            try Output.render(payload: payload, display: display, format: listFormat, quiet: quiet)
        }
    }
}
