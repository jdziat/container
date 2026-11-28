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

/// Which compose files an invocation uses, in merge order.
enum ComposeFiles {
    static let defaultNames = ["compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"]
    static let overrideNames = [
        "compose.override.yaml", "compose.override.yml", "docker-compose.override.yaml", "docker-compose.override.yml",
    ]

    /// An absolute path as-is, a relative one under `directory`. Deliberately not
    /// `URL(fileURLWithPath:relativeTo:)`, which treats a base without a trailing slash that is not on
    /// disk as a file and resolves siblings against its parent (`/proj` + `a.yml` gives `/a.yml`).
    static func url(_ path: String, in directory: URL) -> URL {
        path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : directory.appendingPathComponent(path).standardizedFileURL
    }

    /// Precedence, as in Docker Compose: explicit `-f` files, then `COMPOSE_FILE`, then the default
    /// file in `directory` plus its `*.override.*` sibling (the override is only auto-loaded when
    /// no files were named).
    static func resolve(
        explicit: [String],
        environment: [String: String],
        directory: URL,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) throws -> [URL] {
        if !explicit.isEmpty {
            return explicit.map { url($0, in: directory) }
        }
        if let value = environment["COMPOSE_FILE"], !value.isEmpty {
            let separator = environment["COMPOSE_PATH_SEPARATOR"].flatMap { $0.isEmpty ? nil : $0 } ?? ":"
            return value.components(separatedBy: separator).filter { !$0.isEmpty }.map { url($0, in: directory) }
        }
        for name in defaultNames {
            let candidate = directory.appendingPathComponent(name)
            guard exists(candidate) else { continue }
            var files = [candidate]
            for override in overrideNames {
                let overrideURL = directory.appendingPathComponent(override)
                if exists(overrideURL) {
                    files.append(overrideURL)
                    break
                }
            }
            return files
        }
        throw ComposeError.invalid(
            "no configuration file provided: not found (looked for \(defaultNames.joined(separator: ", ")) in \(directory.path))"
        )
    }
}

/// Compose Spec "merge and override" rules for several files (`-f a.yml -f b.yml`).
///
/// Maps merge recursively; scalars from the later file win; `command`/`entrypoint` are replaced;
/// most lists are appended; `volumes`, `devices`, `secrets` and `configs` merge by their unique key
/// (a later entry for the same mount target replaces the earlier one instead of duplicating it).
/// Pure, so it is unit-tested without any files.
enum ComposeMerge {
    /// Lists that are appended (de-duplicated, order preserved).
    static let appended: Set<String> = [
        "ports", "expose", "external_links", "dns", "dns_search", "dns_opt", "tmpfs", "env_file",
        "cap_add", "cap_drop", "security_opt", "group_add", "profiles",
    ]
    /// Keys that may be written as a list or a mapping; normalized to a mapping before merging.
    static let listOrMap: Set<String> = [
        "environment", "labels", "sysctls", "depends_on", "networks", "extra_hosts", "annotations",
    ]

    static func merge(_ base: [String: Any], _ over: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in over {
            switch key {
            case "services":
                let baseServices = base["services"] as? [String: Any] ?? [:]
                var merged = baseServices
                for (name, service) in (value as? [String: Any]) ?? [:] {
                    if let existing = baseServices[name] as? [String: Any], let incoming = service as? [String: Any] {
                        merged[name] = mergeService(existing, incoming)
                    } else {
                        merged[name] = service
                    }
                }
                result["services"] = merged
            case "networks", "volumes", "configs", "secrets":
                var merged = (base[key] as? [String: Any]) ?? [:]
                for (name, entry) in (value as? [String: Any]) ?? [:] {
                    if entry is NSNull, merged[name] != nil { continue }  // `data:` with no body keeps the earlier definition
                    if let existing = merged[name] as? [String: Any], let incoming = entry as? [String: Any] {
                        merged[name] = deepMerge(existing, incoming)
                    } else {
                        merged[name] = entry
                    }
                }
                result[key] = merged
            default:
                result[key] = value
            }
        }
        return result
    }

    static func mergeService(_ base: [String: Any], _ over: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in over {
            guard let existing = result[key] else {
                result[key] = value
                continue
            }
            result[key] = mergeValue(key: key, base: existing, over: value)
        }
        return result
    }

    static func mergeValue(key: String, base: Any, over: Any) -> Any {
        if appended.contains(key) {
            return dedupe(asList(base) + asList(over))
        }
        switch key {
        case "volumes":
            return mergeKeyed(asList(base), asList(over), key: volumeTarget)
        case "devices":
            return mergeKeyed(asList(base), asList(over), key: deviceTarget)
        case "secrets", "configs":
            return mergeKeyed(asList(base), asList(over), key: artifactSource)
        case "build":
            return deepMerge(buildMap(base), buildMap(over))
        default:
            break
        }
        if listOrMap.contains(key), let baseMap = asMap(base, key: key), let overMap = asMap(over, key: key) {
            return deepMerge(baseMap, overMap)
        }
        if let baseMap = base as? [String: Any], let overMap = over as? [String: Any] {
            return deepMerge(baseMap, overMap)
        }
        return over  // scalars, and command / entrypoint / healthcheck.test: the later file replaces
    }

    static func deepMerge(_ base: [String: Any], _ over: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in over {
            if let existing = result[key] as? [String: Any], let incoming = value as? [String: Any] {
                result[key] = deepMerge(existing, incoming)
            } else if !(value is NSNull) || result[key] == nil {
                result[key] = value
            }
        }
        return result
    }

    // MARK: shapes

    /// A scalar becomes a one-element list; a list stays; anything else is empty.
    static func asList(_ value: Any) -> [Any] {
        if let list = value as? [Any] { return list }
        if value is NSNull { return [] }
        return [value]
    }

    static func buildMap(_ value: Any) -> [String: Any] {
        if let map = value as? [String: Any] { return map }
        if let context = value as? String { return ["context": context] }
        return [:]
    }

    /// `environment: [A=1, B]` and `labels: [k=v]` (list form) as a mapping. A bare name keeps a null value.
    static func asMap(_ value: Any, key: String) -> [String: Any]? {
        if let map = value as? [String: Any] { return map }
        guard let list = value as? [Any] else { return nil }
        var map: [String: Any] = [:]
        for item in list {
            guard let text = item as? String else { continue }
            switch key {
            case "depends_on":
                map[text] = ["condition": "service_started"] as [String: Any]
            case "networks":
                map[text] = [String: Any]()
            case "extra_hosts":
                if let split = text.firstIndex(where: { $0 == ":" || $0 == "=" }) {
                    map[String(text[..<split])] = String(text[text.index(after: split)...])
                }
            default:
                if let split = text.firstIndex(of: "=") {
                    map[String(text[..<split])] = String(text[text.index(after: split)...])
                } else {
                    map[text] = NSNull()
                }
            }
        }
        return map
    }

    static func dedupe(_ list: [Any]) -> [Any] {
        var seen = Set<String>()
        return list.filter { seen.insert("\($0)").inserted }
    }

    static func mergeKeyed(_ base: [Any], _ over: [Any], key: (Any) -> String?) -> [Any] {
        var result = base
        for item in over {
            if let id = key(item), let index = result.firstIndex(where: { key($0) == id }) {
                result[index] = item
            } else {
                result.append(item)
            }
        }
        return result
    }

    /// `src:/target[:mode]`, a lone `/target` (anonymous volume), or `{target: ...}`.
    static func volumeTarget(_ item: Any) -> String? {
        if let text = item as? String {
            let parts = text.split(separator: ":", omittingEmptySubsequences: false)
            return parts.count >= 2 ? String(parts[1]) : parts.first.map(String.init)
        }
        return (item as? [String: Any])?["target"] as? String
    }

    /// `host[:container[:mode]]`: keyed by the container path.
    static func deviceTarget(_ item: Any) -> String? {
        guard let text = item as? String else { return (item as? [String: Any])?["target"] as? String }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count >= 2 ? String(parts[1]) : parts.first.map(String.init)
    }

    static func artifactSource(_ item: Any) -> String? {
        if let text = item as? String { return text }
        return (item as? [String: Any])?["source"] as? String
    }
}
