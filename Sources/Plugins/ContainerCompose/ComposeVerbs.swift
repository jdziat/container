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

/// The decisions behind `compose ps`, `ls`, `cp` and `down --rmi`. Everything here is pure (it works on
/// the JSON `container list` prints, or on the plan), so it is unit-tested without a container system.

// MARK: - ps

struct ComposePSRow: Codable, Equatable {
    var name: String
    var id: String
    var service: String
    var image: String
    var state: String
    var oneOff: Bool

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case id = "ID"
        case service = "Service"
        case image = "Image"
        case state = "State"
        case oneOff = "OneOff"
    }
}

enum ComposePS {
    static let oneOffLabel = "com.docker.compose.oneoff"

    /// This engine says `stopped`; Docker (and every script that filters on it) says `exited`.
    static func normalizeState(_ raw: String) -> String { raw == "stopped" ? "exited" : raw }

    static func rows(listJSON: String, project: String) throws -> [ComposePSRow] {
        let parsed = try ComposeScope.rows(listJSON)
        var result: [ComposePSRow] = []
        for row in parsed {
            let labels = extractLabels(row)
            guard labels[ComposeScope.projectLabel] == project else { continue }
            let config = row["configuration"] as? [String: Any]
            guard let id = config?["id"] as? String else { continue }
            let status =
                (row["status"] as? [String: Any])?["state"] as? String ?? row["status"] as? String ?? "unknown"
            result.append(
                ComposePSRow(
                    name: (config?["name"] as? String) ?? id, id: id,
                    service: labels[ComposeScope.serviceLabel] ?? "",
                    image: ((config?["image"] as? [String: Any])?["reference"] as? String) ?? "",
                    state: normalizeState(status), oneOff: labels[oneOffLabel] == "True"))
        }
        return result.sorted { ($0.service, $0.name) < ($1.service, $1.name) }
    }

    /// Default: running containers only, and no one-offs. `-a` shows everything. `--status` selects
    /// exactly those states (it implies `-a`, as in Docker), but one-offs still need `-a`.
    static func filter(_ rows: [ComposePSRow], all: Bool, statuses: [String]) -> [ComposePSRow] {
        let wanted = Set(statuses.map(normalizeState))
        return rows.filter { row in
            if row.oneOff && !all { return false }
            if !wanted.isEmpty { return wanted.contains(row.state) }
            return all || row.state == "running"
        }
    }

    static func table(_ rows: [ComposePSRow]) -> String {
        let header = ["NAME", "IMAGE", "SERVICE", "STATUS"]
        let body = rows.map { [$0.name, $0.image, $0.service, $0.state] }
        let all = [header] + body
        let widths = header.indices.map { column in all.map { $0[column].count }.max() ?? 0 }
        return all.map { line in
            line.indices.map { line[$0].padding(toLength: widths[$0], withPad: " ", startingAt: 0) }.joined(separator: "  ")
                .trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
    }

    static func json(_ rows: [ComposePSRow]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(rows), as: UTF8.self)
    }
}

// MARK: - ls

struct ComposeProjectSummary: Codable, Equatable {
    var name: String
    var status: String
    var configFiles: String
    var runningCount: Int

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case status = "Status"
        case configFiles = "ConfigFiles"
        case runningCount = "Running"
    }
}

enum ComposeProjects {
    static let configFilesLabel = "com.docker.compose.project.config_files"

    /// Every project that has at least one container, `running(2), exited(1)` style. Projects with nothing
    /// running are hidden unless `all`.
    static func summaries(listJSON: String, all: Bool) throws -> [ComposeProjectSummary] {
        let parsed = try ComposeScope.rows(listJSON)
        var counts: [String: [String: Int]] = [:]
        var files: [String: String] = [:]
        for row in parsed {
            let labels = extractLabels(row)
            guard let project = labels[ComposeScope.projectLabel], !project.isEmpty else { continue }
            let status = (row["status"] as? [String: Any])?["state"] as? String ?? row["status"] as? String ?? "unknown"
            counts[project, default: [:]][ComposePS.normalizeState(status), default: 0] += 1
            if let value = labels[configFilesLabel], files[project] == nil { files[project] = value }
        }
        let order = ["running", "paused", "stopping", "exited", "unknown"]
        return counts.compactMap { project, states in
            let running = states["running"] ?? 0
            guard all || running > 0 else { return nil }
            let text = states.sorted { (order.firstIndex(of: $0.key) ?? 99, $0.key) < (order.firstIndex(of: $1.key) ?? 99, $1.key) }
                .map { "\($0.key)(\($0.value))" }.joined(separator: ", ")
            return ComposeProjectSummary(name: project, status: text, configFiles: files[project] ?? "", runningCount: running)
        }.sorted { $0.name < $1.name }
    }

    static func table(_ rows: [ComposeProjectSummary]) -> String {
        let header = ["NAME", "STATUS", "CONFIG FILES"]
        let all = [header] + rows.map { [$0.name, $0.status, $0.configFiles] }
        let widths = header.indices.map { column in all.map { $0[column].count }.max() ?? 0 }
        return all.map { line in
            line.indices.map { line[$0].padding(toLength: widths[$0], withPad: " ", startingAt: 0) }.joined(separator: "  ")
                .trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
    }
}

// MARK: - cp, down --rmi

extension ComposePlanner.Plan {
    /// `service:path` when `argument` names one of this plan's services before the first colon. A path such as
    /// `./web:x` or `/tmp/web:x` never matches, because a service name cannot contain a slash.
    func serviceReference(_ argument: String) -> (service: String, path: String)? {
        guard let colon = argument.firstIndex(of: ":") else { return nil }
        let prefix = String(argument[..<colon])
        guard !prefix.isEmpty, services.contains(where: { $0.name == prefix }) else { return nil }
        return (prefix, String(argument[argument.index(after: colon)...]))
    }

    /// The container for replica `index` (1-based) of `service`, which must be one this project owns.
    func replicaName(service: String, index: Int, owned: Set<String>) throws -> String {
        guard let svc = services.first(where: { $0.name == service }) else {
            throw ComposeError.invalid("no such service: \(service)")
        }
        let names = Self.plannedContainerNames(svc)
        guard index >= 1, index <= names.count else {
            throw ComposeError.invalid("service \(service) has \(names.count) instance(s); --index \(index) is out of range")
        }
        guard owned.contains(names[index - 1]) else {
            throw ComposeError.invalid("service \(service) has no container (is it up?)")
        }
        return names[index - 1]
    }

    /// `config --format json`: the same facts as the text summary, machine-readable.
    func summaryJSON() throws -> String {
        let payload: [String: Any] = [
            "name": project,
            "network": network,
            "volumes": volumes.keys.sorted(),
            "networks": networks.keys.sorted(),
            "services": services.map { svc -> [String: Any] in
                var entry: [String: Any] = ["name": svc.name, "image": svc.image, "replicas": svc.replicas]
                if svc.build != nil { entry["build"] = true }
                entry["environment"] = svc.environment
                entry["depends_on"] = svc.dependsOn.map(\.service)
                return entry
            },
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// `compose cp SERVICE:SRC DEST` / `compose cp SRC SERVICE:DEST` as the `container copy` arguments.
    /// Exactly one side must be a service; `index` picks the replica (1-based).
    func copyArguments(source: String, destination: String, index: Int, owned: Set<String>) throws -> (String, String) {
        let from = serviceReference(source)
        let to = serviceReference(destination)
        switch (from, to) {
        case (nil, nil):
            throw ComposeError.invalid("compose cp: one of the arguments must be SERVICE:PATH")
        case (.some, .some):
            throw ComposeError.invalid("compose cp: copying between two services is not supported; copy via a local path")
        default:
            break
        }
        if let from {
            return ("\(try replicaName(service: from.service, index: index, owned: owned)):\(from.path)", destination)
        }
        let to2 = to!
        return (source, "\(try replicaName(service: to2.service, index: index, owned: owned)):\(to2.path)")
    }

    /// Images `down --rmi` removes. `local` is only the images compose built itself (the auto-named
    /// `<project>_<service>` tags); `all` is every image a service uses.
    func imagesToRemove(policy: String) throws -> [String] {
        switch policy {
        case "local":
            return Array(Set(services.filter(isAutoBuiltImage).map(\.image))).sorted()
        case "all":
            return Array(Set(services.map(\.image))).sorted()
        default:
            throw ComposeError.invalid("--rmi must be local or all, got '\(policy)'")
        }
    }
}

// MARK: - run

/// What `compose run` changes about the service for this one container.
struct RunOverrides: Equatable {
    var environment: [String] = []  // KEY=VALUE, or KEY to inherit from the host
    var user: String?
    var workdir: String?
    var entrypoint: String?
    var publish: [String] = []
    var servicePorts = false
    var name: String?
    var labels: [String] = []
}

extension ComposePlanner.Plan {
    /// The service as `compose run` runs it. Unlike `up`, the service's own `ports:` are NOT published
    /// (two `run`s would fight over them, and Docker doesn't) unless `--service-ports`; `-p` adds ports.
    func oneOffService(_ service: String, overrides: RunOverrides, hostEnvironment: [String: String]) throws
        -> ComposePlanner.Service
    {
        guard var svc = services.first(where: { $0.name == service }) else {
            throw ComposeError.invalid("no such service: \(service)")
        }
        for entry in overrides.environment {
            if let equals = entry.firstIndex(of: "=") {
                svc.environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
            } else if let value = hostEnvironment[entry] {
                svc.environment[entry] = value
            }
        }
        if let user = overrides.user { svc.user = user }
        if let workdir = overrides.workdir { svc.workingDir = workdir }
        if let entrypoint = overrides.entrypoint { svc.entrypoint = entrypoint.isEmpty ? nil : [entrypoint] }
        if !overrides.servicePorts { svc.ports = [] }
        svc.ports += overrides.publish
        for label in overrides.labels {
            if let equals = label.firstIndex(of: "=") {
                svc.labels[String(label[..<equals])] = String(label[label.index(after: equals)...])
            } else {
                svc.labels[label] = ""
            }
        }
        // A one-off must not start its own replicas, healthcheck-gated restarts or restart policy.
        svc.restart = nil
        svc.replicas = 1
        if let name = overrides.name { svc.containerName = name }
        return svc
    }

    /// The plan holding only what `service` depends on (not the service itself): what `compose run` starts
    /// first unless `--no-deps`.
    func dependencies(of service: String) throws -> ComposePlanner.Plan {
        let closure = try selecting([service], withDependencies: true)
        var narrowed = closure
        narrowed.services = closure.services.filter { $0.name != service }
        return narrowed
    }
}

// MARK: - logs

enum ComposeLogs {
    /// `web-1  | line`, with names padded to the widest so the bars line up, as Docker prints them.
    static func prefix(_ line: String, name: String, width: Int, enabled: Bool) -> String {
        guard enabled else { return line }
        return name.padding(toLength: max(width, name.count), withPad: " ", startingAt: 0) + "  | " + line
    }

    /// Containers to read, in service order then replica order, only those that exist.
    static func targets(plan: ComposePlanner.Plan, services: [String], owned: Set<String>) throws -> [String] {
        try plan.selecting(services, withDependencies: false).services
            .flatMap { ComposePlanner.Plan.plannedContainerNames($0) }.filter { owned.contains($0) }
    }
}

// MARK: - exec

enum ComposeExec {
    /// `container exec` arguments. Docker's `compose exec` allocates a TTY by default; this one does so only
    /// when both ends are terminals, so piping `exec` output into a file or another command is not corrupted.
    static func arguments(
        container: String, command: [String], detach: Bool, env: [String], user: String?, workdir: String?, tty: Bool
    ) -> [String] {
        var args = ["exec"]
        if detach { args.append("--detach") }
        if tty { args += ["--interactive", "--tty"] }
        for entry in env { args += ["--env", entry] }
        if let user { args += ["--user", user] }
        if let workdir { args += ["--workdir", workdir] }
        return args + [container] + command
    }
}

/// Reads a child process's stdout line by line, printing each through `transform`. Lines from several
/// containers are written whole under a lock so they never interleave mid-line.
enum ComposeLogStreamer {
    private static let lock = NSLock()

    static func stream(args: [String], transform: @escaping (String) -> String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [ContainerCLI.current] + args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.standardError
        try process.run()
        var buffer = Data()
        while true {
            let chunk = out.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                buffer = Data(buffer[buffer.index(after: newline)...])
                emit(transform(line))
            }
        }
        if !buffer.isEmpty { emit(transform(String(decoding: buffer, as: UTF8.self))) }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ComposeError.commandFailed("container \(args.joined(separator: " ")) failed with exit \(process.terminationStatus)")
        }
    }

    private static func emit(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}

// MARK: - --dry-run

/// `compose --dry-run <verb>`: read what exists, print what would change, change nothing.
enum ComposeDryRun {
    nonisolated(unsafe) static var enabled = false

    /// True when running `args` through the `container` CLI would change something. This is an allowlist of
    /// reads, so a verb added later is treated as mutating (printed, never run) until someone says otherwise.
    static func isMutating(_ args: [String]) -> Bool {
        guard let first = args.first else { return false }
        switch first {
        case "list", "ls", "inspect", "logs", "--version":
            return false
        case "system":
            return args.dropFirst().first != "status"
        case "network", "volume", "image", "builder":
            return !["list", "ls", "inspect"].contains(args.dropFirst().first ?? "")
        default:
            return true
        }
    }

    static func describe(_ args: [String]) -> String {
        "[dry-run] container " + args.map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")
    }
}

// MARK: - run dependencies

/// What `compose run` must do about each dependency, given the project's containers right now. Docker reuses a
/// dependency that exists (starting it when stopped) and only creates what is missing; creating one whose
/// name is taken fails with a name conflict.
struct ComposeRunDependencies: Equatable {
    var create: [String] = []  // services with no container yet
    var start: [String] = []  // existing containers that are not running
    var running: [String] = []  // already up, left alone

    static func decide(dependencies: [ComposePlanner.Service], rows: [ComposePSRow]) -> ComposeRunDependencies {
        let state = Dictionary(rows.map { ($0.name, $0.state) }, uniquingKeysWith: { first, _ in first })
        var result = ComposeRunDependencies()
        for service in dependencies {
            let names = ComposePlanner.Plan.plannedContainerNames(service)
            let missing = names.filter { state[$0] == nil }
            if missing.count == names.count {
                result.create.append(service.name)
            } else {
                // Every planned name exists (a partial set is treated the same: start what is there).
                for name in names where state[name] != nil {
                    if state[name] == "running" { result.running.append(name) } else { result.start.append(name) }
                }
            }
        }
        return result
    }
}
