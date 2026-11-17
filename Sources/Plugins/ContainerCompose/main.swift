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
import Foundation
import Yams

@main
struct ContainerCompose: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compose",
        abstract: "Run multi-container stacks from a Compose file",
        subcommands: [Up.self, Down.self, Config.self],
        defaultSubcommand: Up.self
    )
}

extension ContainerCompose {
    struct SharedOptions: ParsableArguments {
        @Option(name: [.short, .customLong("file")], help: "Compose file path")
        var file: String = "compose.yaml"

        @Option(name: .shortAndLong, help: "Project name (default: directory name)")
        var project: String?
    }

    struct Up: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create and start services")

        @OptionGroup var shared: SharedOptions

        @Flag(name: .customLong("detach"), help: "Detached mode")
        var detach = true

        func run() async throws {
            let plan = try ComposePlanner.plan(fileURL: URL(fileURLWithPath: shared.file), project: shared.project)
            try plan.reportUnsupported()
            try await plan.up(detach: detach)
        }
    }

    struct Down: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop and remove services")

        @OptionGroup var shared: SharedOptions

        func run() async throws {
            let plan = try ComposePlanner.plan(fileURL: URL(fileURLWithPath: shared.file), project: shared.project)
            try await plan.down()
        }
    }

    struct Config: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Validate and print the resolved plan")

        @OptionGroup var shared: SharedOptions

        func run() throws {
            let plan = try ComposePlanner.plan(fileURL: URL(fileURLWithPath: shared.file), project: shared.project)
            try plan.reportUnsupported()
            print(try plan.summary())
        }
    }
}

struct ComposePlanner {
    enum DependCondition: String, Sendable {
        case serviceStarted = "service_started"
        case serviceHealthy = "service_healthy"
    }

    struct Dependency: Sendable {
        var service: String
        var condition: DependCondition
    }

    struct HealthcheckSpec: Sendable {
        var test: String
        var intervalSeconds: UInt64?
        var timeoutSeconds: UInt64?
        var startPeriodSeconds: UInt64?
        var retries: UInt64?
    }

    struct Service: Sendable {
        var name: String
        var image: String
        var command: [String]
        var environment: [String: String]
        var ports: [String]
        var volumes: [String]
        var dependsOn: [Dependency]
        var restart: String?
        var healthcheck: HealthcheckSpec?
    }

    struct Plan: Sendable {
        var project: String
        var network: String
        var services: [Service]
        var unsupported: [(service: String?, key: String, reason: String)]

        func reportUnsupported() throws {
            guard !unsupported.isEmpty else { return }
            var lines = ["unsupported compose keys (fail closed):"]
            for item in unsupported {
                let scope = item.service.map { "service \($0): " } ?? ""
                lines.append("  - \(scope)\(item.key): \(item.reason)")
            }
            throw ComposeError.unsupported(lines.joined(separator: "\n"))
        }

        func summary() throws -> String {
            var lines = ["project: \(project)", "network: \(network)", "services:"]
            for service in services {
                var detail = "  - \(service.name) image=\(service.image)"
                if service.healthcheck != nil { detail += " healthcheck=yes" }
                let healthyDeps = service.dependsOn.filter { $0.condition == .serviceHealthy }.map(\.service)
                if !healthyDeps.isEmpty {
                    detail += " waits_healthy=[\(healthyDeps.joined(separator: ","))]"
                }
                lines.append(detail)
            }
            return lines.joined(separator: "\n")
        }

        func up(detach: Bool) async throws {
            _ = try runContainer(["network", "create", network])
            for service in services {
                // Dependencies are started earlier by topo order; wait for healthy when requested.
                for dep in service.dependsOn where dep.condition == .serviceHealthy {
                    try await waitUntilHealthy(dep.service)
                }
                var args = ["run"]
                if detach { args.append("-d") }
                // Use the compose service name as the container ID so peer /etc/hosts
                // injection can resolve bare names like `db` without a DNS domain or
                // single-label alias= (which AliasPolicy rejects when no domain is set).
                args += ["--name", service.name, "--network", network]
                for (key, value) in service.environment.sorted(by: { $0.key < $1.key }) {
                    args += ["-e", "\(key)=\(value)"]
                }
                for port in service.ports {
                    args += ["-p", port]
                }
                for volume in service.volumes {
                    args += ["-v", volume]
                }
                if let restart = service.restart {
                    args += ["--restart", restart]
                }
                if let health = service.healthcheck {
                    args += ["--health-cmd", health.test]
                    if let interval = health.intervalSeconds {
                        args += ["--health-interval", "\(interval)"]
                    }
                    if let timeout = health.timeoutSeconds {
                        args += ["--health-timeout", "\(timeout)"]
                    }
                    if let startPeriod = health.startPeriodSeconds {
                        args += ["--health-start-period", "\(startPeriod)"]
                    }
                    if let retries = health.retries {
                        args += ["--health-retries", "\(retries)"]
                    }
                }
                args.append(service.image)
                args += service.command
                _ = try runContainer(args)
            }
        }

        func down() async throws {
            for service in services.reversed() {
                _ = try? runContainer(["stop", service.name])
                _ = try? runContainer(["delete", "-f", service.name])
            }
            _ = try? runContainer(["network", "delete", network])
        }
    }

    static func plan(fileURL: URL, project: String?) throws -> Plan {
        let data = try Data(contentsOf: fileURL)
        guard let root = try Yams.load(yaml: String(data: data, encoding: .utf8) ?? "") as? [String: Any] else {
            throw ComposeError.invalid("compose file is not a mapping")
        }
        var unsupported: [(service: String?, key: String, reason: String)] = []
        for key in root.keys where !["services", "networks", "volumes", "name", "version"].contains(key) {
            unsupported.append((nil, key, "top-level key is not supported in this curated subset"))
        }

        let projectName =
            project
            ?? (root["name"] as? String)
            ?? fileURL.deletingLastPathComponent().lastPathComponent
        let network = "\(projectName)_default"

        guard let servicesMap = root["services"] as? [String: Any] else {
            throw ComposeError.invalid("compose file missing services")
        }

        var services: [Service] = []
        for (name, raw) in servicesMap {
            guard let body = raw as? [String: Any] else {
                throw ComposeError.invalid("service \(name) is not a mapping")
            }
            for key in body.keys {
                let allowed: Set<String> = [
                    "image", "command", "entrypoint", "environment", "ports", "volumes",
                    "depends_on", "restart", "container_name", "healthcheck", "build",
                ]
                if !allowed.contains(key) {
                    unsupported.append((name, key, "not implemented in curated compose plugin"))
                }
            }
            if body["build"] != nil {
                unsupported.append((name, "build", "run `container build` first; build: is not executed by this plugin yet"))
            }
            guard let image = body["image"] as? String else {
                throw ComposeError.invalid("service \(name) requires image:")
            }
            var environment: [String: String] = [:]
            if let envMap = body["environment"] as? [String: Any] {
                for (k, v) in envMap {
                    environment[k] = "\(v)"
                }
            } else if let envList = body["environment"] as? [String] {
                for item in envList {
                    let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
                    if parts.count == 2 {
                        environment[parts[0]] = parts[1]
                    }
                }
            }
            let ports = (body["ports"] as? [Any] ?? []).map { "\($0)" }
            let volumes = (body["volumes"] as? [Any] ?? []).map { "\($0)" }
            let dependsOn = try parseDependsOn(body["depends_on"], service: name)
            let healthcheck = try parseHealthcheck(body["healthcheck"], service: name)
            let command: [String]
            if let cmd = body["command"] as? [String] {
                command = cmd
            } else if let cmd = body["command"] as? String {
                command = ["sh", "-c", cmd]
            } else {
                command = []
            }
            services.append(
                Service(
                    name: name,
                    image: image,
                    command: command,
                    environment: environment,
                    ports: ports,
                    volumes: volumes,
                    dependsOn: dependsOn,
                    restart: body["restart"] as? String,
                    healthcheck: healthcheck
                ))
        }

        // Topological-ish order: dependencies first; stable by name otherwise.
        services.sort { lhs, rhs in
            let rhsNeedsLhs = rhs.dependsOn.contains { $0.service == lhs.name }
            let lhsNeedsRhs = lhs.dependsOn.contains { $0.service == rhs.name }
            if rhsNeedsLhs { return true }
            if lhsNeedsRhs { return false }
            return lhs.name < rhs.name
        }

        return Plan(project: projectName, network: network, services: services, unsupported: unsupported)
    }

    private static func parseDependsOn(_ raw: Any?, service: String) throws -> [Dependency] {
        guard let raw else { return [] }
        if let deps = raw as? [String] {
            return deps.map { Dependency(service: $0, condition: .serviceStarted) }
        }
        guard let deps = raw as? [String: Any] else {
            throw ComposeError.invalid("service \(service): depends_on must be a list or mapping")
        }
        var result: [Dependency] = []
        for (depName, value) in deps {
            if value is String {
                result.append(Dependency(service: depName, condition: .serviceStarted))
                continue
            }
            guard let body = value as? [String: Any] else {
                throw ComposeError.invalid("service \(service): depends_on.\(depName) must be a mapping")
            }
            let conditionRaw = (body["condition"] as? String) ?? DependCondition.serviceStarted.rawValue
            guard let condition = DependCondition(rawValue: conditionRaw) else {
                throw ComposeError.invalid(
                    "service \(service): unsupported depends_on condition \"\(conditionRaw)\" (supported: service_started, service_healthy)"
                )
            }
            result.append(Dependency(service: depName, condition: condition))
        }
        return result.sorted { $0.service < $1.service }
    }

    private static func parseHealthcheck(_ raw: Any?, service: String) throws -> HealthcheckSpec? {
        guard let raw else { return nil }
        guard let body = raw as? [String: Any] else {
            throw ComposeError.invalid("service \(service): healthcheck must be a mapping")
        }
        if let disable = body["disable"] as? Bool, disable {
            return nil
        }
        let test: String
        if let argv = body["test"] as? [String], !argv.isEmpty {
            let data = try JSONSerialization.data(withJSONObject: argv)
            test = String(data: data, encoding: .utf8) ?? argv.joined(separator: " ")
        } else if let shell = body["test"] as? String, !shell.isEmpty {
            test = shell
        } else {
            throw ComposeError.invalid("service \(service): healthcheck.test is required")
        }
        return HealthcheckSpec(
            test: test,
            intervalSeconds: try optionalDurationSeconds(body["interval"], field: "interval", service: service),
            timeoutSeconds: try optionalDurationSeconds(body["timeout"], field: "timeout", service: service),
            startPeriodSeconds: try optionalDurationSeconds(body["start_period"], field: "start_period", service: service),
            retries: optionalUInt64(body["retries"])
        )
    }

    private static func optionalUInt64(_ raw: Any?) -> UInt64? {
        if let n = raw as? UInt64 { return n }
        if let n = raw as? Int, n >= 0 { return UInt64(n) }
        if let s = raw as? String { return UInt64(s) }
        return nil
    }

    private static func optionalDurationSeconds(_ raw: Any?, field: String, service: String) throws -> UInt64? {
        guard let raw else { return nil }
        if let n = raw as? Int, n >= 0 { return UInt64(n) }
        if let n = raw as? UInt64 { return n }
        if let s = raw as? String {
            return try parseDurationSeconds(s, field: field, service: service)
        }
        throw ComposeError.invalid("service \(service): healthcheck.\(field) must be a duration string or integer seconds")
    }

    /// Parse Compose-style durations (`5s`, `1m`, `1m30s`) or bare integer seconds.
    static func parseDurationSeconds(_ raw: String, field: String, service: String) throws -> UInt64 {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let n = UInt64(trimmed) { return n }
        var total: UInt64 = 0
        var number = ""
        for ch in trimmed {
            if ch.isNumber {
                number.append(ch)
                continue
            }
            guard let value = UInt64(number), !number.isEmpty else {
                throw ComposeError.invalid("service \(service): invalid healthcheck.\(field) duration \"\(raw)\"")
            }
            number = ""
            switch ch {
            case "s": total &+= value
            case "m": total &+= value &* 60
            case "h": total &+= value &* 3600
            default:
                throw ComposeError.invalid("service \(service): invalid healthcheck.\(field) duration \"\(raw)\"")
            }
        }
        if !number.isEmpty {
            throw ComposeError.invalid("service \(service): invalid healthcheck.\(field) duration \"\(raw)\"")
        }
        return total
    }
}

func waitUntilHealthy(_ containerId: String, timeoutSeconds: UInt64 = 300) async throws {
    let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
    while Date() < deadline {
        let json = try runContainer(["inspect", containerId])
        if let status = healthStatus(fromInspectJSON: json) {
            if status == "healthy" { return }
            if status == "unhealthy" {
                throw ComposeError.commandFailed("dependency \(containerId) became unhealthy while waiting")
            }
        }
        try await Task.sleep(for: .seconds(1))
    }
    throw ComposeError.commandFailed("timed out waiting for \(containerId) to become healthy")
}

func healthStatus(fromInspectJSON json: String) -> String? {
    guard let data = json.data(using: .utf8),
        let root = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
        let first = root.first
    else {
        return nil
    }
    if let configuration = first["configuration"] as? [String: Any],
        let status = configuration["healthStatus"] as? String
    {
        return status
    }
    if let status = first["healthStatus"] as? String {
        return status
    }
    return nil
}

enum ComposeError: Error, CustomStringConvertible {
    case invalid(String)
    case unsupported(String)
    case commandFailed(String)

    var description: String {
        switch self {
        case .invalid(let message), .unsupported(let message), .commandFailed(let message):
            return message
        }
    }
}

@discardableResult
func runContainer(_ args: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["container"] + args
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try process.run()
    process.waitUntilExit()
    let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
        throw ComposeError.commandFailed("container \(args.joined(separator: " ")) failed: \(stderr)\(stdout)")
    }
    return stdout
}
