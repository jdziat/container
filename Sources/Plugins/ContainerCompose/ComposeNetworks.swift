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

/// Top-level `networks:` entries. Pure, so it is unit-tested without a container system.
///
/// Naming matches Docker Compose: a network the project creates is `<project>_<key>` unless it sets
/// `name:`, while an `external` network is looked up by `name:` or, failing that, by its plain key
/// (never project-prefixed, because it exists independently of this project).
enum ComposeNetworkParser {
    struct Parsed {
        var network: ComposePlanner.ProjectNetwork
        var unsupported: [(key: String, reason: String)] = []
        var warnings: [String] = []
    }

    static let knownKeys: Set<String> = [
        "name", "driver", "driver_opts", "external", "internal", "labels", "ipam", "attachable", "enable_ipv6",
        "enable_ipv4",
    ]

    static func parse(key: String, value: Any, project: String) throws -> Parsed {
        let created = "\(project)_\(key)"
        if value is NSNull {
            return Parsed(network: .init(name: created, driver: nil, external: false, aliases: []))
        }
        guard let body = value as? [String: Any] else {
            throw ComposeError.invalid("networks.\(key) must be a mapping")
        }

        var external = false
        var externalName: String?
        switch body["external"] {
        case let flag as Bool: external = flag
        case let legacy as [String: Any]:
            external = true
            externalName = ComposeScalar.string(legacy["name"])
        default: break
        }
        let name = ComposeScalar.string(body["name"]) ?? externalName ?? (external ? key : created)

        var parsed = Parsed(network: .init(name: name, driver: ComposeScalar.string(body["driver"]), external: external, aliases: []))
        func reject(_ field: String, _ reason: String) { parsed.unsupported.append(("networks.\(key).\(field)", reason)) }

        for field in body.keys where !knownKeys.contains(field) && !field.hasPrefix("x-") {
            reject(field, "not implemented")
        }
        // An external network already exists, so how it is configured is not this project's business.
        if external { return parsed }

        if let driver = parsed.network.driver, !["", "bridge", "default"].contains(driver) {
            reject("driver", "only the bridge driver is available (got '\(driver)')")
        }
        if let flag = body["internal"] {
            guard let value = ComposeScalar.bool(flag) else { throw ComposeError.invalid("networks.\(key).internal must be a boolean") }
            parsed.network.isInternal = value
        }
        if let raw = body["labels"], let map = ComposeMerge.asMap(raw, key: "labels") {
            for (label, value) in map { parsed.network.labels[label] = ComposeScalar.string(value) ?? "" }
        }
        if let raw = body["driver_opts"] as? [String: Any] {
            for (option, value) in raw { parsed.network.driverOpts[option] = ComposeScalar.string(value) ?? "" }
        }
        for field in ["attachable", "enable_ipv6"] where ComposeScalar.bool(body[field]) == true {
            parsed.warnings.append("network \(key): \(field) is accepted but has no effect")
        }
        try parseIPAM(body["ipam"], key: key, into: &parsed)
        return parsed
    }

    /// `ipam.config[].subnet` becomes `--subnet` / `--subnet-v6` (one of each at most). Gateways, ranges and
    /// auxiliary addresses cannot be set, and are rejected rather than ignored.
    private static func parseIPAM(_ raw: Any?, key: String, into parsed: inout Parsed) throws {
        guard let raw else { return }
        guard let ipam = raw as? [String: Any] else { throw ComposeError.invalid("networks.\(key).ipam must be a mapping") }
        func reject(_ field: String, _ reason: String) { parsed.unsupported.append(("networks.\(key).ipam.\(field)", reason)) }
        if let driver = ComposeScalar.string(ipam["driver"]), driver != "default" {
            reject("driver", "only the default IPAM driver is available")
        }
        for entry in (ipam["config"] as? [Any]) ?? [] {
            guard let config = entry as? [String: Any] else { throw ComposeError.invalid("networks.\(key).ipam.config entries must be mappings") }
            for field in ["gateway", "ip_range", "aux_addresses"] where config[field] != nil {
                reject(field, "\(field) cannot be set; the gateway and range are chosen by the network")
            }
            guard let subnet = ComposeScalar.string(config["subnet"]) else { continue }
            if subnet.contains(":") {
                guard subnet.contains("/") else { throw ComposeError.invalid("networks.\(key).ipam subnet '\(subnet)' needs a prefix length") }
                if parsed.network.subnetV6 == nil { parsed.network.subnetV6 = subnet } else { reject("config", "only one IPv6 subnet is supported") }
            } else {
                guard subnet.range(of: #"^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$"#, options: .regularExpression) != nil else {
                    throw ComposeError.invalid("networks.\(key).ipam subnet '\(subnet)' must look like 172.28.0.0/16")
                }
                if parsed.network.subnet == nil { parsed.network.subnet = subnet } else { reject("config", "only one IPv4 subnet is supported") }
            }
        }
    }
}

extension ComposePlanner.Plan {
    /// `container network create` arguments for a project network (`spec == nil` is the implicit default).
    /// Every network is labeled with the project so `down` only ever removes what this project created.
    func networkCreateArgs(name: String, key: String, spec: ComposePlanner.ProjectNetwork?) -> [String] {
        var args = [
            "network", "create", "--label", "com.docker.compose.project=\(project)", "--label",
            "com.docker.compose.network=\(key)",
        ]
        if let spec {
            for (label, value) in spec.labels.sorted(by: { $0.key < $1.key }) { args += ["--label", "\(label)=\(value)"] }
            if spec.isInternal { args.append("--internal") }
            if let subnet = spec.subnet { args += ["--subnet", subnet] }
            if let subnet = spec.subnetV6 { args += ["--subnet-v6", subnet] }
            for (option, value) in spec.driverOpts.sorted(by: { $0.key < $1.key }) { args += ["--option", "\(option)=\(value)"] }
        }
        args.append(name)
        return args
    }
}

extension ComposeScope {
    /// Networks carrying this project's label. `down` deletes only these (intersected with the networks the
    /// file declares), so a same-named network somebody else created is never removed.
    static func ownedNetworkNames(listJSON: String, project: String) throws -> Set<String> {
        guard let data = listJSON.data(using: .utf8),
            let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { throw ComposeError.commandFailed("network list returned unparseable JSON") }
        var names = Set<String>()
        for row in rows where extractLabels(row)[projectLabel] == project {
            if let name = (row["configuration"] as? [String: Any])?["name"] as? String ?? row["id"] as? String {
                names.insert(name)
            }
        }
        return names
    }
}
