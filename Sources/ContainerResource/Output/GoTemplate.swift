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

import Foundation

/// A deliberately small subset of Go's `text/template`, enough for the Docker CLI
/// one-liners people put in scripts: `{{.Field}}`, `{{.A.B}}`, `{{json .}}`,
/// `{{json .Field}}`, `{{upper .X}}`, `{{lower .X}}`, `{{title .X}}`, `{{join .List ","}}`,
/// and the `\t` / `\n` escapes. Anything else is rejected loudly rather than
/// silently rendered wrong.
///
/// The template is evaluated against the command's already-encoded JSON payload, so
/// every command that can emit `--format json` can also emit a template, with
/// field names matched case-insensitively (Docker uses `.Names`, this model uses `name`).
public enum GoTemplate {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// True when `format` looks like a Go template rather than a named format.
    public static func isTemplate(_ format: String) -> Bool {
        format.contains("{{")
    }

    /// Well-known Docker field names mapped onto this project's JSON keys.
    private static let aliases: [String: [String]] = [
        "names": ["name", "id"], "name": ["name", "id"], "id": ["id"],
        "image": ["image"], "status": ["status", "state"], "state": ["status", "state"],
        "ports": ["ports", "publishedports"], "repository": ["repository", "name"],
        "tag": ["tag"], "size": ["size"], "createdat": ["createdat", "creationdate", "created"],
        "labels": ["labels"], "command": ["command"], "networks": ["networks"],
        "ipaddress": ["ipaddress", "ipv4address", "ip"],
    ]

    public static func render(_ template: String, rows: [Any]) throws -> String {
        // `table <template>` prints a header of the (upper-cased) field names, as Docker does.
        if template.hasPrefix("table ") || template.hasPrefix("table\t") {
            let body = String(template.dropFirst("table".count)).trimmingCharacters(in: .whitespaces)
            let header = headerLine(for: body)
            let lines = try rows.map { try render(body, row: $0) }
            return ([header] + lines).joined(separator: "\n")
        }
        return try rows.map { try render(template, row: $0) }.joined(separator: "\n")
    }

    private static func headerLine(for template: String) -> String {
        let source = template.replacingOccurrences(of: "\\t", with: "\t")
        var names: [String] = []
        var rest = source[...]
        while let open = rest.range(of: "{{"), let close = rest.range(of: "}}", range: open.upperBound..<rest.endIndex) {
            let action = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            let field = tokenize(action).last ?? ""
            names.append(field.hasPrefix(".") ? String(field.dropFirst()).uppercased() : field.uppercased())
            rest = rest[close.upperBound...]
        }
        return names.joined(separator: "\t")
    }

    public static func render(_ template: String, row: Any) throws -> String {
        let source =
            template
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\n", with: "\n")
        var output = ""
        var index = source.startIndex
        while index < source.endIndex {
            guard let open = source.range(of: "{{", range: index..<source.endIndex) else {
                output += source[index...]
                break
            }
            output += source[index..<open.lowerBound]
            guard let close = source.range(of: "}}", range: open.upperBound..<source.endIndex) else {
                throw Failure(description: "unterminated action in template: \(template)")
            }
            let action = source[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            output += try evaluate(action, row: row)
            index = close.upperBound
        }
        return output
    }

    private static func evaluate(_ action: String, row: Any) throws -> String {
        let parts = tokenize(action)
        guard let head = parts.first else { return "" }
        switch head {
        case "json":
            guard parts.count == 2 else { throw Failure(description: "json takes exactly one argument") }
            return try encode(resolve(parts[1], in: row))
        case "upper", "lower", "title":
            guard parts.count == 2 else { throw Failure(description: "\(head) takes exactly one argument") }
            let text = display(resolve(parts[1], in: row))
            switch head {
            case "upper": return text.uppercased()
            case "lower": return text.lowercased()
            default: return titleCase(text)
            }
        case "join":
            guard parts.count == 3 else { throw Failure(description: "join takes a list and a separator") }
            let separator = parts[2].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard let list = resolve(parts[1], in: row) as? [Any] else { return "" }
            return list.map { display($0) }.joined(separator: separator)
        default:
            guard parts.count == 1, head.hasPrefix(".") else {
                throw Failure(description: "unsupported template action '\(action)'")
            }
            return display(resolve(head, in: row))
        }
    }

    private static func titleCase(_ text: String) -> String {
        var result = ""
        var startOfWord = true
        for character in text {
            result += startOfWord ? character.uppercased() : String(character)
            startOfWord = character == " " || character == "\t" || character == "-" || character == "_"
        }
        return result
    }

    private static func tokenize(_ action: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quoted = false
        for character in action {
            if character == "\"" {
                quoted.toggle()
                current.append(character)
                continue
            }
            if character == " " && !quoted {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// Resolve `.A.B` against decoded JSON; `.` is the whole row. Missing fields are
    /// `nil`, which renders as `<no value>` like Go does. Reference-like objects are only
    /// unwrapped on the final segment so explicit paths such as `.Status.state` still work.
    private static func resolve(_ path: String, in row: Any) -> Any? {
        guard path != "." else { return row }
        let segments = path.split(separator: ".").map(String.init)
        var current: Any? = row
        for (index, segment) in segments.enumerated() {
            guard let object = current as? [String: Any] else { return nil }
            let value = lookup(segment, in: object)
            current = index == segments.count - 1 ? unwrap(value, field: segment) : value
        }
        return current
    }

    /// Case-insensitive lookup of Docker's flat names against this project's nested
    /// payloads. `configuration` is searched first so `.Name` is the human name rather
    /// than the top-level UUID; `status` last.
    private static func lookup(_ segment: String, in object: [String: Any]) -> Any? {
        let wanted = segment.lowercased()
        let scopes = [object["configuration"] as? [String: Any], object, object["status"] as? [String: Any]]
            .compactMap { $0 }
        // Derived fields: Docker splits an image reference into repository and tag.
        if wanted == "repository" || wanted == "tag" {
            // Image rows only. A container has no repository; its `name` is not one.
            guard object["status"] == nil else { return nil }
            let reference = (scopes.lazy.compactMap { lookupDirect(["name", "reference"], in: $0) }.first)
                .flatMap { unwrap($0, field: "name") as? String }
            guard let reference else { return nil }
            let (repository, tag) = splitReference(reference)
            return wanted == "repository" ? repository : tag
        }
        let candidates = [wanted] + (aliases[wanted] ?? [])
        for scope in scopes {
            if let found = lookupDirect(candidates, in: scope) { return found }
        }
        return nil
    }

    private static func lookupDirect(_ candidates: [String], in scope: [String: Any]) -> Any? {
        for candidate in candidates {
            if let key = scope.keys.first(where: { $0.lowercased() == candidate }) { return scope[key] }
        }
        return nil
    }

    /// `docker.io/library/alpine:3.20` -> (`docker.io/library/alpine`, `3.20`); digests dropped.
    private static func splitReference(_ reference: String) -> (String, String) {
        let name = reference.split(separator: "@", maxSplits: 1).first.map(String.init) ?? reference
        if let colon = name.lastIndex(of: ":"), !name[colon...].contains("/") {
            return (String(name[..<colon]), String(name[name.index(after: colon)...]))
        }
        // A digest-only reference has no tag (Docker prints <none>); a bare name defaults to latest.
        return (name, reference.contains("@") ? "<none>" : "latest")
    }

    /// Docker flattens a few structured fields to a scalar (`.Image` is a string, `.Status` the state).
    /// That is only valid for those named fields. Unwrapping ANY object with a `name`/`id`/... key
    /// would let a user label called `name` replace an entire `.Labels` map with its value.
    private static func unwrap(_ value: Any?, field: String) -> Any? {
        guard let object = value as? [String: Any] else { return value }
        let keys: [String]
        switch field.lowercased() {
        case "status", "state": keys = ["state"]
        case "image", "name", "names": keys = ["reference", "name"]
        default: return value
        }
        for key in keys { if let inner = object[key] { return inner } }
        return value
    }

    private static func display(_ value: Any?) -> String {
        switch value {
        case nil: return "<no value>"
        case let string as String: return string
        case let number as NSNumber:
            // JSON booleans arrive as NSNumber; Go prints them true/false, not 1/0.
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue
        case let list as [Any]: return list.map { display($0) }.joined(separator: ",")
        default: return (try? encode(value)) ?? "\(value as Any)"
        }
    }

    private static func encode(_ value: Any?) throws -> String {
        guard let value, JSONSerialization.isValidJSONObject(["v": value]) else {
            return value.map { "\"\(display($0))\"" } ?? "null"
        }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}

extension Output {
    /// Renders `payload` through a Go-style template, one output line per element.
    /// The payload is round-tripped through its JSON encoding so templates see exactly
    /// what `--format json` shows.
    public static func renderTemplate<J: Encodable>(_ template: String, payload: J) throws {
        emit(try renderedTemplate(template, payload: payload))
    }

    /// The string `renderTemplate` prints. Separate so tests exercise the real encode-then-render path.
    public static func renderedTemplate<J: Encodable>(_ template: String, payload: J) throws -> String {
        let data = try JSONEncoder().encode(payload)
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        let rows: [Any] = (object as? [Any]) ?? [object]
        return try GoTemplate.render(template, rows: rows)
    }
}
