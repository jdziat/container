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

/// Compose service keys that map straight onto `container run` flags.
///
/// Parsing and flag generation are pure (no I/O), so every mapping is unit-tested without a
/// running system. Keys the per-container-VM model cannot honor are NOT silently dropped: they are
/// either rejected (fail closed) or accepted with one explicit warning, and the compose support
/// matrix says which is which.
struct ServiceOptions: Sendable, Equatable {
    var ulimits: [String] = []
    var sysctls: [String] = []
    var extraHosts: [String] = []
    var dns: [String] = []
    var dnsSearch: [String] = []
    var dnsOptions: [String] = []
    var stopSignal: String?
    var useInit = false
    var readOnly = false
    var platform: String?
    var cpus: String?
    var memory: String?
    var macAddress: String?
    var pullPolicy: PullPolicy?

    enum PullPolicy: String, Sendable, Equatable {
        case always, missing, never, build
    }

    /// `container run` flags for these options, in a stable order.
    func runFlags() -> [String] {
        var args: [String] = []
        for value in ulimits { args += ["--ulimit", value] }
        for value in sysctls { args += ["--sysctl", value] }
        for value in extraHosts { args += ["--add-host", value] }
        for value in dns { args += ["--dns", value] }
        for value in dnsSearch { args += ["--dns-search", value] }
        for value in dnsOptions { args += ["--dns-option", value] }
        if let stopSignal { args += ["--stop-signal", stopSignal] }
        if useInit { args.append("--init") }
        if readOnly { args.append("--read-only") }
        if let platform { args += ["--platform", platform] }
        if let cpus { args += ["--cpus", cpus] }
        if let memory { args += ["--memory", memory] }
        return args
    }
}

struct ServiceOptionsParse {
    var options = ServiceOptions()
    var warnings: [String] = []
    var unsupported: [(key: String, reason: String)] = []
}

/// Loosely typed YAML scalars (Yams yields Int, Double, Bool, String, ...).
enum ComposeScalar {
    static func string(_ raw: Any?) -> String? {
        switch raw {
        case let value as String: return value
        case let value as Bool: return value ? "true" : "false"
        case let value as Int: return String(value)
        case let value as Int64: return String(value)
        case let value as UInt64: return String(value)
        case let value as Double:
            return value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value)
        default: return nil
        }
    }

    static func double(_ raw: Any?) -> Double? {
        switch raw {
        case let value as Double: return value
        case let value as Int: return Double(value)
        case let value as Int64: return Double(value)
        case let value as UInt64: return Double(value)
        case let value as String: return Double(value.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    static func bool(_ raw: Any?) -> Bool? {
        switch raw {
        case let value as Bool: return value
        case let value as String:
            switch value.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        default: return nil
        }
    }

    /// A scalar or a list of scalars, as strings.
    static func list(_ raw: Any?) -> [String] {
        if let list = raw as? [Any] { return list.compactMap { string($0) } }
        return string(raw).map { [$0] } ?? []
    }
}

enum ServiceOptionsParser {
    /// Keys accepted but with no effect on this engine, and why. Reported once per plan as a warning.
    static let ignoredWithWarning: [String: String] = [
        "privileged": "each container already runs in its own VM; use devices: for host devices",
        "security_opt": "there is no seccomp/AppArmor profile selection",
        "pid": "containers cannot share the host PID namespace",
        "ipc": "containers cannot share the host IPC namespace",
        "uts": "containers cannot share the host UTS namespace",
        "cgroup": "there is no cgroup namespace selection",
        "cgroup_parent": "there are no host cgroups to parent under",
        "logging": "logs always use the built-in driver",
        "expose": "it is metadata only; publish ports with ports:",
        "userns_mode": "user namespaces are not configurable",
        "isolation": "isolation is not configurable",
        "oom_score_adj": "the guest OOM score is not configurable",
        "oom_kill_disable": "the guest OOM killer is not configurable",
        "cpu_shares": "CPU shares are not configurable; use cpus:",
        "cpu_quota": "CPU quota is not configurable; use cpus:",
        "cpu_period": "CPU period is not configurable; use cpus:",
        "cpu_rt_runtime": "realtime CPU limits are not configurable",
        "cpu_rt_period": "realtime CPU limits are not configurable",
        "cpuset": "CPU pinning is not configurable",
        "cpu_count": "use cpus:",
        "cpu_percent": "use cpus:",
        "mem_reservation": "soft memory limits are not configurable; use mem_limit:",
        "memswap_limit": "swap limits are not configurable",
        "mem_swappiness": "swappiness is not configurable",
        "blkio_config": "block I/O limits are not configurable",
        "pids_limit": "there is no per-container pids cgroup limit",
        "runtime": "there is a single runtime",
        "storage_opt": "storage options are not configurable",
        "annotations": "annotations are metadata only",
        "develop": "`compose watch` reads it; it has no effect on `up`",
        "tty": "a detached container's stdio is closed after start, so a pty has no reader (a bare `sh` still exits)",
        "stdin_open": "a detached container's stdin is closed after start (a bare `sh` still exits)",
    ]

    /// Every key this parser owns: implemented, or deliberately accepted with a warning.
    static let acceptedKeys: Set<String> = Set(ignoredWithWarning.keys).union([
        "ulimits", "sysctls", "extra_hosts", "dns", "dns_search", "dns_opt", "stop_signal", "init",
        "read_only", "platform", "cpus", "mem_limit", "mac_address", "pull_policy", "network_mode", "scale",
    ])

    /// Specific reasons for keys that are rejected, so the error says why rather than "not implemented".
    static let rejectedReasons: [String: String] = [
        "links": "links are legacy; containers on a network reach each other by service name",
        "external_links": "external_links are legacy; attach to the shared network instead",
        "volumes_from": "volumes_from is not supported; declare a named volume and mount it in both services",
        "group_add": "supplementary groups are not supported",
        "network_mode": "only the default bridge is available (each container is its own VM)",
        "lifecycle": "container lifecycle hooks are not supported",
        "post_start": "lifecycle hooks are not supported",
        "pre_stop": "lifecycle hooks are not supported",
    ]

    static func parse(body: [String: Any], service: String) throws -> ServiceOptionsParse {
        var result = ServiceOptionsParse()
        func invalid(_ message: String) -> ComposeError { .invalid("service \(service): \(message)") }

        // --- values that map onto run flags -------------------------------------------------
        if let raw = body["ulimits"] {
            guard let map = raw as? [String: Any] else { throw invalid("ulimits must be a mapping") }
            for (name, value) in map.sorted(by: { $0.key < $1.key }) {
                if let single = ComposeScalar.string(value), !(value is [String: Any]) {
                    result.options.ulimits.append("\(name)=\(single)")
                } else if let limits = value as? [String: Any],
                    let soft = ComposeScalar.string(limits["soft"]), let hard = ComposeScalar.string(limits["hard"])
                {
                    result.options.ulimits.append("\(name)=\(soft):\(hard)")
                } else {
                    throw invalid("ulimits.\(name) must be a number or {soft, hard}")
                }
            }
        }

        if let raw = body["sysctls"] {
            if let map = raw as? [String: Any] {
                for (key, value) in map.sorted(by: { $0.key < $1.key }) {
                    guard var text = ComposeScalar.string(value) else { throw invalid("sysctls.\(key) must be a scalar") }
                    if value is Bool { text = (value as? Bool) == true ? "1" : "0" }
                    result.options.sysctls.append("\(key)=\(text)")
                }
            } else if let list = raw as? [Any] {
                for item in list {
                    guard let text = ComposeScalar.string(item), text.contains("=") else {
                        throw invalid("sysctls entries must be key=value")
                    }
                    result.options.sysctls.append(text)
                }
            } else {
                throw invalid("sysctls must be a mapping or a list")
            }
        }

        if let raw = body["extra_hosts"] {
            func add(_ host: String, _ address: String) {
                if address == "host-gateway" {
                    result.unsupported.append(
                        ("extra_hosts", "host-gateway is not supported; use the gateway IP instead"))
                } else {
                    result.options.extraHosts.append("\(host):\(address)")
                }
            }
            if let map = raw as? [String: Any] {
                for (host, value) in map.sorted(by: { $0.key < $1.key }) {
                    for address in ComposeScalar.list(value) { add(host, address) }
                }
            } else if let list = raw as? [Any] {
                for item in list {
                    guard let text = ComposeScalar.string(item),
                        let split = text.firstIndex(where: { $0 == ":" || $0 == "=" })
                    else { throw invalid("extra_hosts entries must be host:ip or host=ip") }
                    add(String(text[..<split]), String(text[text.index(after: split)...]))
                }
            } else {
                throw invalid("extra_hosts must be a mapping or a list")
            }
        }

        result.options.dns = ComposeScalar.list(body["dns"])
        result.options.dnsSearch = ComposeScalar.list(body["dns_search"])
        result.options.dnsOptions = ComposeScalar.list(body["dns_opt"])
        result.options.stopSignal = ComposeScalar.string(body["stop_signal"])
        if body["init"] != nil {
            guard let flag = ComposeScalar.bool(body["init"]) else { throw invalid("init must be a boolean") }
            result.options.useInit = flag
        }
        if body["read_only"] != nil {
            guard let flag = ComposeScalar.bool(body["read_only"]) else { throw invalid("read_only must be a boolean") }
            result.options.readOnly = flag
        }
        result.options.platform = ComposeScalar.string(body["platform"])

        // --- resources: service-level keys win over deploy.resources.limits ----------------
        let limits = ((body["deploy"] as? [String: Any])?["resources"] as? [String: Any])?["limits"] as? [String: Any]
        if let raw = body["cpus"] ?? limits?["cpus"] {
            guard let value = ComposeScalar.double(raw) else { throw invalid("cpus must be a number") }
            result.options.cpus = try normalizeCPUs(value, service: service, warnings: &result.warnings)
        }
        if let raw = body["mem_limit"] ?? limits?["memory"] {
            guard let text = ComposeScalar.string(raw) else { throw invalid("mem_limit must be a size") }
            result.options.memory = try normalizeMemory(
                text, field: body["mem_limit"] != nil ? "mem_limit" : "deploy.resources.limits.memory",
                service: service, warnings: &result.warnings)
        }

        if let raw = body["mac_address"] {
            guard let text = ComposeScalar.string(raw),
                text.range(of: #"^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$"#, options: .regularExpression) != nil
            else { throw invalid("mac_address must look like 02:42:ac:11:00:02") }
            result.options.macAddress = text
        }

        if let raw = body["pull_policy"] {
            guard let text = ComposeScalar.string(raw)?.lowercased() else { throw invalid("pull_policy must be a string") }
            switch text {
            case "always": result.options.pullPolicy = .always
            case "never": result.options.pullPolicy = .never
            case "missing", "if_not_present": result.options.pullPolicy = .missing
            case "build": result.options.pullPolicy = .build
            case "daily", "weekly":
                result.options.pullPolicy = .missing
                result.warnings.append("service \(service): pull_policy \(text) is treated as missing (no pull-age tracking)")
            default:
                guard text.hasPrefix("every_") else {
                    throw invalid("pull_policy '\(text)' is not one of always, never, missing, build, daily, weekly")
                }
                result.options.pullPolicy = .missing
                result.warnings.append("service \(service): pull_policy \(text) is treated as missing (no pull-age tracking)")
            }
        }

        // --- network_mode: only the default bridge exists ------------------------------------
        if let mode = ComposeScalar.string(body["network_mode"]), !["", "bridge", "default"].contains(mode) {
            result.unsupported.append(
                ("network_mode", "network_mode '\(mode)' is not supported: " + (rejectedReasons["network_mode"] ?? "")))
        }

        // --- accepted with no effect: one warning each, only when set to something non-default ---
        for (key, reason) in ignoredWithWarning.sorted(by: { $0.key < $1.key }) {
            guard let value = body[key], !isDefault(value) else { continue }
            result.warnings.append("service \(service): \(key) is accepted but has no effect (\(reason))")
        }
        return result
    }

    private static func isDefault(_ value: Any) -> Bool {
        switch value {
        case let flag as Bool: return !flag
        case let text as String: return text.isEmpty
        case let list as [Any]: return list.isEmpty
        case let map as [String: Any]: return map.isEmpty
        case let number as Int: return number == 0
        case let number as Double: return number == 0
        default: return false
        }
    }

    /// `container run --cpus` takes whole CPUs; round fractional requests up and say so.
    static func normalizeCPUs(_ value: Double, service: String, warnings: inout [String]) throws -> String {
        guard value > 0 else { throw ComposeError.invalid("service \(service): cpus must be greater than 0") }
        let whole = Int(value.rounded(.up))
        if Double(whole) != value {
            warnings.append("service \(service): cpus \(value) rounded up to \(whole) (whole CPUs only)")
        }
        return "\(whole)"
    }

    /// Compose sizes (`512m`, `1g`, `1gb`, `1073741824`) to `container run --memory` form (whole MiB).
    static func normalizeMemory(_ raw: String, field: String, service: String, warnings: inout [String]) throws -> String {
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let bad = ComposeError.invalid(
            "service \(service): \(field) '\(raw)' is not a size (examples: 512m, 1g, 1gb, 1073741824)")
        guard let regex = try? NSRegularExpression(pattern: #"^([0-9]+(?:\.[0-9]+)?)\s*([kmgtp]?)(?:i?b)?$"#),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let numberRange = Range(match.range(at: 1), in: text), let value = Double(text[numberRange])
        else { throw bad }
        let unit = Range(match.range(at: 2), in: text).map { String(text[$0]) } ?? ""
        let multipliers: [String: Double] = [
            "": 1, "k": 1024, "m": 1_048_576, "g": 1_073_741_824, "t": 1_099_511_627_776,
            "p": 1_125_899_906_842_624,
        ]
        let mebibytes = value * (multipliers[unit] ?? 1) / 1_048_576
        guard mebibytes > 0 else { throw bad }
        let whole = max(1, Int(mebibytes.rounded(.up)))
        if Double(whole) != mebibytes {
            warnings.append("service \(service): \(field) '\(raw)' rounded up to \(whole)M (1 MiB granularity)")
        }
        return "\(whole)M"
    }
}
