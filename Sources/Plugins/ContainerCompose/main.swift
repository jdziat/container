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
        abstract: "Run multi-container stacks from a Compose file (Docker Compose v2–shaped)",
        subcommands: [
            Up.self, Down.self, Config.self, Doctor.self, Ps.self, Logs.self, Exec.self, Run.self, Build.self,
            Pull.self, Images.self, Stop.self, Start.self, Restart.self, Rm.self, Kill.self, Pause.self, Unpause.self,
            Top.self, Port.self, Create.self,
        ],
        defaultSubcommand: Up.self
    )

    static func main() async {
        do {
            let args = try hoistGlobalOptions(Array(CommandLine.arguments.dropFirst()))
            var command = try parseAsRoot(args)
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch {
            exit(withError: error)
        }
    }

    /// Docker Compose takes `-f`, `-p`/`--project-name` and `--profile` *before* the subcommand
    /// (`docker compose -f x.yml up`). ArgumentParser scopes options to the command they are
    /// declared on, and a short `-f` on the shared options would collide with `logs -f` (follow)
    /// and `rm -f` (force). So accept the Docker spelling here and rewrite it to the per-subcommand
    /// long form: `-f x up` becomes `up --file=x`. Everything after the subcommand is untouched,
    /// so `logs -f` still means follow.
    static func hoistGlobalOptions(_ args: [String]) throws -> [String] {
        let valued: [String: String] = [
            "-f": "--file", "--file": "--file",
            "-p": "--project", "--project-name": "--project", "--project": "--project",
            "--profile": "--profile",
        ]
        var hoisted: [String] = []
        var files = 0
        var index = 0
        while index < args.count {
            let token = args[index]
            guard token.hasPrefix("-"), token != "--help", token != "-h" else { break }
            if let eq = token.firstIndex(of: "="), let target = valued[String(token[..<eq])] {
                if target == "--file" { files += 1 }
                hoisted.append("\(target)=\(token[token.index(after: eq)...])")
                index += 1
            } else if let target = valued[token] {
                guard index + 1 < args.count else {
                    throw ValidationError("option '\(token)' requires a value")
                }
                if target == "--file" { files += 1 }
                hoisted.append("\(target)=\(args[index + 1])")
                index += 2
            } else if token.count > 2, !token.hasPrefix("--"), let target = valued[String(token.prefix(2))] {
                // Attached short form: `-fFILE`, `-pNAME` (Docker accepts these).
                if target == "--file" { files += 1 }
                hoisted.append("\(target)=\(token.dropFirst(2))")
                index += 1
            } else {
                // Unknown leading option (for example --help): leave everything for ArgumentParser.
                return args
            }
        }
        guard files <= 1 else {
            throw ValidationError("multiple -f/--file values are not supported (merge the files first, or use `extends`)")
        }
        guard index < args.count else { return hoisted + args[index...] }
        // args[index] is the subcommand; global options follow it.
        return [args[index]] + hoisted + args[(index + 1)...]
    }
}

extension ContainerCompose {
    struct SharedOptions: ParsableArguments {
        @Option(name: .customLong("file"), help: "Compose file path")
        var file: String = "compose.yaml"

        @Option(name: .shortAndLong, help: "Project name (default: directory name)")
        var project: String?

        @Option(name: .long, help: "Activate profile (repeatable)")
        var profile: [String] = []
    }

    struct Up: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create and start services")

        @OptionGroup var shared: SharedOptions

        @Flag(name: [.customShort("d"), .customLong("detach")], help: "Detached mode (always on; accepted for CLI compatibility)")
        var detach = false

        @Flag(name: .long, help: "Build images before starting (services with build: are always built; accepted for compatibility)")
        var build = false

        @Flag(name: .long, help: "Wait for services to be running/healthy (depends_on conditions are always honored)")
        var wait = false

        @Flag(name: .long, help: "Recreate containers even if configuration is unchanged")
        var forceRecreate = false

        @Flag(name: .long, help: "Do not start linked services (all services in the file are started)")
        var noDeps = false

        @Flag(name: .long, help: "Remove containers for services not defined in the compose file")
        var removeOrphans = false

        func run() async throws {
            let plan = try ComposePlanner.plan(
                fileURL: URL(fileURLWithPath: shared.file),
                project: shared.project,
                profiles: shared.profile
            )
            try plan.reportUnsupported()
            _ = (detach, build, wait)
            if forceRecreate { try await plan.removeExisting() }
            if removeOrphans { try await plan.removeOrphans() }
            try await plan.up(detach: true)
        }
    }

    struct Down: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop and remove services")

        @OptionGroup var shared: SharedOptions

        @Flag(name: [.customShort("v"), .customLong("volumes")], help: "Also remove named volumes declared in the compose file")
        var volumes = false

        @Option(name: [.customShort("t"), .customLong("timeout")], help: "Minimum stop timeout in seconds")
        var timeout: Int?

        @Flag(name: .long, help: "Remove containers for services not defined in the compose file")
        var removeOrphans = false

        func run() async throws {
            let plan = try ComposePlanner.plan(
                fileURL: URL(fileURLWithPath: shared.file),
                project: shared.project,
                profiles: shared.profile
            )
            try await plan.down(minimumStopTimeout: timeout)
            if volumes { try plan.removeProjectVolumes() }
        }
    }

    struct Config: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Validate and print the resolved plan")

        @OptionGroup var shared: SharedOptions

        func run() async throws {
            let plan = try ComposePlanner.plan(
                fileURL: URL(fileURLWithPath: shared.file),
                project: shared.project,
                profiles: shared.profile
            )
            try plan.reportUnsupported()
            print(try plan.summary())
        }
    }

    /// Preflight for per-container VM loud edges (Pack B). Does not start services.
    struct Doctor: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Preflight Compose file for VM-model loud edges (aliases, volumes, devices, NFS)"
        )

        @OptionGroup var shared: SharedOptions

        @Flag(name: .long, help: "Exit non-zero on fail or warn findings")
        var strict = false

        func run() async throws {
            let plan = try ComposePlanner.plan(
                fileURL: URL(fileURLWithPath: shared.file),
                project: shared.project,
                profiles: shared.profile
            )
            let findings = plan.doctorFindings()
            if findings.isEmpty {
                print("compose doctor: ok (no loud-edge findings)")
                return
            }
            print("compose doctor: \(findings.count) finding(s) for project \(plan.project)")
            for finding in findings {
                print("\(finding.severity.rawValue.uppercased()) [\(finding.code)] \(finding.message)")
            }
            let blocking = findings.contains { $0.severity == .fail || (strict && $0.severity == .warn) }
            if blocking {
                throw ComposeError.unsupported(
                    "compose doctor found issues; fix the file or run without --strict (see docs/docker-job-catalog.md)"
                )
            }
        }
    }

    struct Ps: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List containers for the project")

        @OptionGroup var shared: SharedOptions

        @Flag(name: .shortAndLong, help: "Only display container names")
        var quiet = false

        func run() async throws {
            let plan = try ComposePlanner.plan(
                fileURL: URL(fileURLWithPath: shared.file),
                project: shared.project,
                profiles: shared.profile
            )
            let ids = try plan.projectContainerIDs()
            if quiet {
                for id in ids.sorted() { print(id) }
                return
            }
            print("NAME\tIMAGE\tSTATUS")
            if ids.isEmpty { return }
            for id in ids.sorted() {
                do {
                    let row = try inspectRow(id)
                    print("\(row.name)\t\(row.image)\t\(row.status)")
                } catch {
                    FileHandle.standardError.write(Data("compose ps: inspect \(id) failed: \(error)\n".utf8))
                    print("\(id)\t?\t?")
                }
            }
        }
    }

    struct Logs: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "View output from services")

        @OptionGroup var shared: SharedOptions

        @Argument(help: "Service name")
        var service: String

        @Flag(name: .shortAndLong, help: "Follow log output")
        var follow = false

        @Option(name: .long, help: "Number of lines to show from the end of the logs")
        var tail: Int?

        func run() async throws {
            let plan = try ComposePlanner.plan(
                fileURL: URL(fileURLWithPath: shared.file),
                project: shared.project,
                profiles: shared.profile
            )
            let name = try plan.containerName(for: service)
            var args = ["logs"]
            if follow { args.append("--follow") }
            if let tail { args += ["-n", "\(tail)"] }
            args.append(name)
            try runContainerStreaming(args)
        }
    }

    struct Exec: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Execute a command in a running service")

        @OptionGroup var shared: SharedOptions

        @Argument(help: "Service name")
        var service: String

        @Argument(parsing: .remaining, help: "Command to run")
        var command: [String] = []

        func run() async throws {
            let plan = try ComposePlanner.plan(
                fileURL: URL(fileURLWithPath: shared.file),
                project: shared.project,
                profiles: shared.profile
            )
            let name = try plan.containerName(for: service)
            guard !command.isEmpty else {
                throw ComposeError.invalid("compose exec requires a command")
            }
            try runContainerStreaming(["exec", name] + command)
        }
    }

    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Run a one-off command on a service")

        @OptionGroup var shared: SharedOptions

        @Flag(name: .long, help: "Remove the one-off container after it exits (always on for compose run)")
        var rm = false

        @Argument(help: "Service name")
        var service: String

        @Argument(parsing: .remaining, help: "Command override")
        var command: [String] = []

        func run() async throws {
            let plan = try ComposePlanner.plan(
                fileURL: URL(fileURLWithPath: shared.file),
                project: shared.project,
                profiles: shared.profile
            )
            try plan.reportUnsupported()
            try await plan.runOneOff(service: service, command: command)
        }
    }

    struct Build: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Build or rebuild services")

        @OptionGroup var shared: SharedOptions

        @Flag(name: .long, help: "Do not use cache when building images")
        var noCache = false

        @Argument(help: "Service names (default: all with build:)")
        var services: [String] = []

        func run() async throws {
            let plan = try ComposePlanner.plan(
                fileURL: URL(fileURLWithPath: shared.file),
                project: shared.project,
                profiles: shared.profile
            )
            try plan.reportUnsupported()
            try plan.build(only: services.isEmpty ? nil : Set(services), noCache: noCache)
        }
    }

    struct Pull: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Pull service images")

        @OptionGroup var shared: SharedOptions

        @Flag(name: .long, help: "Continue if pulling an image fails")
        var ignorePullFailures = false

        @Argument(help: "Service names (default: all)")
        var services: [String] = []

        func run() async throws {
            let plan = try ComposePlanner.plan(
                fileURL: URL(fileURLWithPath: shared.file),
                project: shared.project,
                profiles: shared.profile
            )
            try plan.reportUnsupported()
            _ = ignorePullFailures
            try plan.pull(only: services.isEmpty ? nil : Set(services))
        }
    }

    struct Images: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List images used by the project")

        @OptionGroup var shared: SharedOptions

        func run() async throws {
            let plan = try ComposePlanner.plan(
                fileURL: URL(fileURLWithPath: shared.file),
                project: shared.project,
                profiles: shared.profile
            )
            print("CONTAINER\tREPOSITORY\tTAG")
            for service in plan.services {
                for name in ComposePlanner.Plan.plannedContainerNames(service) {
                    let (repo, tag) = splitImageRepositoryTag(service.image)
                    print("\(name)\t\(repo)\t\(tag)")
                }
            }
        }
    }
}

// MARK: - Lifecycle verbs (thin wrappers over `container` for project containers)

extension ContainerCompose {
    /// Resolve service names (or all project containers) to concrete container names.
    ///
    /// Only containers that carry THIS project's compose label are ever returned. A service named
    /// `web` must not resolve to an unrelated container that happens to be called `web`: these
    /// verbs include `rm -f` and `kill`. Services with no container yet are skipped, as Docker
    /// does, rather than failing the whole command.
    static func targets(plan: ComposePlanner.Plan, services: [String]) throws -> [String] {
        let owned = try plan.projectContainerNames()
        if services.isEmpty {
            return owned.sorted()
        }
        return try services.flatMap { name -> [String] in
            guard let svc = plan.services.first(where: { $0.name == name }) else {
                throw ComposeError.invalid("unknown service \(name)")
            }
            return ComposePlanner.Plan.plannedContainerNames(svc).filter { owned.contains($0) }
        }
    }

    static func loadPlan(_ shared: SharedOptions) throws -> ComposePlanner.Plan {
        try ComposePlanner.plan(
            fileURL: URL(fileURLWithPath: shared.file), project: shared.project, profiles: shared.profile)
    }

    struct Stop: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop services")
        @OptionGroup var shared: SharedOptions
        @Option(name: [.customShort("t"), .customLong("timeout")], help: "Stop timeout in seconds")
        var timeout: Int?
        @Argument var services: [String] = []
        func run() async throws {
            let names = try ContainerCompose.targets(plan: try ContainerCompose.loadPlan(shared), services: services)
            guard !names.isEmpty else { return }
            var args = ["stop"]
            if let timeout { args += ["-t", "\(timeout)"] }
            _ = try runContainer(args + names)
        }
    }

    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Start existing service containers")
        @OptionGroup var shared: SharedOptions
        @Argument var services: [String] = []
        func run() async throws {
            let names = try ContainerCompose.targets(plan: try ContainerCompose.loadPlan(shared), services: services)
            for name in names { _ = try runContainer(["start", name]) }
        }
    }

    struct Restart: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Restart service containers")
        @OptionGroup var shared: SharedOptions
        @Option(name: [.customShort("t"), .customLong("timeout")], help: "Stop timeout in seconds")
        var timeout: Int?
        @Argument var services: [String] = []
        func run() async throws {
            let names = try ContainerCompose.targets(plan: try ContainerCompose.loadPlan(shared), services: services)
            for name in names {
                var args = ["restart"]
                if let timeout { args += ["-t", "\(timeout)"] }
                _ = try runContainer(args + [name])
            }
        }
    }

    struct Rm: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove stopped service containers")
        @OptionGroup var shared: SharedOptions
        @Flag(name: [.customShort("f"), .customLong("force")], help: "Remove running containers too")
        var force = false
        @Flag(name: [.customShort("s"), .customLong("stop")], help: "Stop containers before removing")
        var stop = false
        @Argument var services: [String] = []
        func run() async throws {
            let names = try ContainerCompose.targets(plan: try ContainerCompose.loadPlan(shared), services: services)
            for name in names {
                if stop { _ = try? runContainer(["stop", name]) }
                _ = try runContainer(["delete"] + (force ? ["-f"] : []) + [name])
            }
        }
    }

    struct Kill: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Force-stop service containers")
        @OptionGroup var shared: SharedOptions
        @Option(name: [.customShort("s"), .customLong("signal")], help: "Signal to send (default KILL)")
        var signal: String?
        @Argument var services: [String] = []
        func run() async throws {
            let names = try ContainerCompose.targets(plan: try ContainerCompose.loadPlan(shared), services: services)
            for name in names {
                _ = try runContainer(["kill"] + (signal.map { ["-s", $0] } ?? []) + [name])
            }
        }
    }

    struct Pause: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Pause service containers")
        @OptionGroup var shared: SharedOptions
        @Argument var services: [String] = []
        func run() async throws {
            let names = try ContainerCompose.targets(plan: try ContainerCompose.loadPlan(shared), services: services)
            if !names.isEmpty { _ = try runContainer(["pause"] + names) }
        }
    }

    struct Unpause: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Unpause service containers")
        @OptionGroup var shared: SharedOptions
        @Argument var services: [String] = []
        func run() async throws {
            let names = try ContainerCompose.targets(plan: try ContainerCompose.loadPlan(shared), services: services)
            if !names.isEmpty { _ = try runContainer(["unpause"] + names) }
        }
    }

    struct Top: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Display running processes of service containers")
        @OptionGroup var shared: SharedOptions
        @Argument var services: [String] = []
        func run() async throws {
            let names = try ContainerCompose.targets(plan: try ContainerCompose.loadPlan(shared), services: services)
            for name in names {
                print("\(name)")
                try runContainerStreaming(["exec", name, "ps", "aux"])
            }
        }
    }

    struct Port: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the public port for a published service port")
        @OptionGroup var shared: SharedOptions
        @Argument var service: String
        @Argument var privatePort: String?
        func run() async throws {
            let name = try ContainerCompose.loadPlan(shared).containerName(for: service)
            try runContainerStreaming(["port", name])
        }
    }

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create service containers without starting them")
        @OptionGroup var shared: SharedOptions
        func run() async throws {
            let plan = try ContainerCompose.loadPlan(shared)
            try plan.reportUnsupported()
            try await plan.up(detach: true, startContainers: false)
        }
    }
}

// MARK: - Locating the `container` CLI (pure; unit-tested)

/// Which `container` binary the plugin drives. Resolved from the plugin's OWN install tree so a
/// stale `container` elsewhere on PATH (an older build, a different version) is never used by
/// accident, and so it works on a machine where `container` is not on PATH at all (CI).
enum ContainerCLI {
    /// 1. `CONTAINER_CLI` if set (explicit override).
    /// 2. The nearest `<ancestor>/bin/container` above the plugin executable.
    /// 3. Plain `container`, resolved through PATH by `env`.
    static func resolve(
        environment: [String: String],
        pluginExecutable: String,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String {
        if let explicit = environment["CONTAINER_CLI"], !explicit.isEmpty { return explicit }
        var directory = URL(fileURLWithPath: pluginExecutable).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent("bin/container").path
            if isExecutable(candidate) { return candidate }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return "container"
    }

    /// The resolution for this process.
    static var current: String {
        let executable = Bundle.main.executablePath ?? CommandLine.arguments.first ?? ""
        return resolve(
            environment: ProcessInfo.processInfo.environment,
            pluginExecutable: URL(fileURLWithPath: executable).resolvingSymlinksInPath().path)
    }
}

// MARK: - Project scoping (pure; unit-tested)

/// Decides which containers and volumes belong to a compose project. Kept free of I/O so the
/// destructive verbs (`rm`, `kill`, `down`, `--force-recreate`, `--remove-orphans`, `down -v`) can
/// be tested without a running system. Everything here keys on the project's compose label: a
/// resource that merely shares a service's name is never ours.
enum ComposeScope {
    static let projectLabel = "com.docker.compose.project"
    static let serviceLabel = "com.docker.compose.service"

    private static func rows(_ json: String) throws -> [[String: Any]] {
        guard let data = json.data(using: .utf8),
            let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { throw ComposeError.commandFailed("list returned unparseable JSON") }
        return rows
    }

    /// (name, id) of every container carrying this project's label.
    static func ownedContainers(listJSON: String, project: String) throws -> [(name: String, id: String)] {
        try rows(listJSON).compactMap { row in
            guard extractLabels(row)[projectLabel] == project,
                let cfg = row["configuration"] as? [String: Any], let id = cfg["id"] as? String
            else { return nil }
            return ((cfg["name"] as? String) ?? id, id)
        }
    }

    /// Ids of project containers whose service is not declared in the file at all. A container of a
    /// declared-but-profile-disabled service is not an orphan, and neither is one with no service
    /// label (an unknown one is left alone rather than guessed at).
    static func orphanContainerIDs(listJSON: String, project: String, declaredServices: Set<String>) throws -> [String] {
        try rows(listJSON).compactMap { row in
            let labels = extractLabels(row)
            guard labels[projectLabel] == project, let service = labels[serviceLabel],
                !declaredServices.contains(service),
                let cfg = row["configuration"] as? [String: Any], let id = cfg["id"] as? String
            else { return nil }
            return id
        }
    }

    /// Volumes `down -v` may delete: carry this project's label AND are declared by the file.
    static func removableVolumeNames(listJSON: String, project: String, declared: Set<String>) throws -> [String] {
        try rows(listJSON).compactMap { row in
            guard extractLabels(row)[projectLabel] == project,
                let cfg = row["configuration"] as? [String: Any], let name = cfg["name"] as? String,
                declared.contains(name)
            else { return nil }
            return name
        }
    }
}

// MARK: - Planner

struct ComposePlanner {
    enum DependCondition: String, Sendable {
        case serviceStarted = "service_started"
        case serviceHealthy = "service_healthy"
        case serviceCompletedSuccessfully = "service_completed_successfully"
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

    struct BuildSpec: Sendable {
        var context: String
        var dockerfile: String?
        var target: String?
        var args: [String: String]
        var tags: [String]
    }

    struct ProjectVolume: Sendable {
        var name: String
        var driver: String
        var driverOpts: [String: String]
        var external: Bool
    }

    struct ProjectNetwork: Sendable {
        var name: String
        var driver: String?
        var external: Bool
        var aliases: [String]
    }

    struct ServiceNetwork: Sendable {
        var name: String
        var aliases: [String]
    }

    struct Service: Sendable {
        var name: String
        var containerName: String?
        var image: String
        var build: BuildSpec?
        var command: [String]
        var entrypoint: [String]?
        var environment: [String: String]
        var ports: [String]
        /// Short-form `-v` specs and/or already-expanded `--mount` specs.
        var volumeShort: [String]
        var mounts: [String]
        var tmpfs: [String]
        var dependsOn: [Dependency]
        var restart: String?
        var healthcheck: HealthcheckSpec?
        var labels: [String: String]
        var workingDir: String?
        var user: String?
        var hostname: String?
        var domainname: String?
        var shmSize: String?
        var profiles: [String]
        var networks: [ServiceNetwork]
        var stopGracePeriod: String?
        var capAdd: [String]
        var capDrop: [String]
        /// F3 allowlist host devices (`HOST[:CONTAINER[:MODE]]`).
        var devices: [String]
        /// From `deploy.replicas` (interim subset; capped at 3 at plan time).
        var replicas: Int
    }

    struct Plan: Sendable {
        var project: String
        var network: String
        var composeFileDir: URL
        var services: [Service]
        var volumes: [String: ProjectVolume]
        var networks: [String: ProjectNetwork]
        var unsupported: [(service: String?, key: String, reason: String)]
        /// Every service named in the file, including ones a profile left out of `services`. A container
        /// whose service is declared here is never an orphan.
        var declaredServices: Set<String> = []

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
            var lines = [
                "project: \(project)",
                "network: \(network)",
                "volumes: \(volumes.keys.sorted().joined(separator: ", "))",
                "networks: \(networks.keys.sorted().joined(separator: ", "))",
                "services:",
            ]
            for service in services {
                var detail = "  - \(service.name) image=\(service.image)"
                if service.build != nil { detail += " build=yes" }
                if service.healthcheck != nil { detail += " healthcheck=yes" }
                let healthyDeps = service.dependsOn.filter { $0.condition == .serviceHealthy }.map(\.service)
                if !healthyDeps.isEmpty {
                    detail += " waits_healthy=[\(healthyDeps.joined(separator: ","))]"
                }
                if !service.environment.isEmpty {
                    let env = service.environment.sorted(by: { $0.key < $1.key })
                        .map { "\($0.key)=\($0.value)" }
                        .joined(separator: ",")
                    detail += " env=[\(env)]"
                }
                lines.append(detail)
            }
            return lines.joined(separator: "\n")
        }

        enum DoctorSeverity: String, Sendable {
            case fail
            case warn
            case info
        }

        struct DoctorFinding: Sendable {
            var severity: DoctorSeverity
            var code: String
            var message: String
        }

        /// Loud-edge preflight for migrants (aliases, single-writer volumes, devices, NFS, sock).
        func doctorFindings() -> [DoctorFinding] {
            var findings: [DoctorFinding] = []

            for item in unsupported {
                let scope = item.service.map { "service \($0): " } ?? ""
                findings.append(
                    DoctorFinding(
                        severity: .fail,
                        code: "unsupported-key",
                        message: "\(scope)\(item.key): \(item.reason)"
                    )
                )
            }

            var rwWriters: [String: [String]] = [:]
            var needsNFS = false
            for service in services {
                for volume in Self.rwNamedVolumeSources(service: service, projectVolumes: volumes) {
                    rwWriters[volume, default: []].append(service.name)
                }
                if Self.usesNFS(service: service, projectVolumes: volumes) {
                    needsNFS = true
                }
                if Self.bindMountsDockerSock(service: service) {
                    findings.append(
                        DoctorFinding(
                            severity: .warn,
                            code: "docker-sock",
                            message:
                                "service \(service.name) bind-mounts docker.sock. "
                                + "In-core apiserver bind is out of scope. First-class working path: "
                                + "Recipe B (privileged bridge at /var/run/docker.sock) in "
                                + "docs/docker-job-catalog.md; Recipe A/C work with DOCKER_HOST "
                                + "or a Docker context. Or remove the mount."
                        )
                    )
                }
            }
            for (volume, writers) in rwWriters.sorted(by: { $0.key < $1.key }) where writers.count > 1 {
                findings.append(
                    DoctorFinding(
                        severity: .info,
                        code: "named-volume-single-writer",
                        message:
                            "named volume \"\(volume)\" is mounted read-write by services "
                            + "\(writers.joined(separator: ", ")). Default local volumes use the shared "
                            + "virtiofs plane (multi-writer). Block-image volumes (--opt backend=block) "
                            + "remain exclusive; see docs/volumes.md."
                    )
                )
            }
            if needsNFS {
                findings.append(
                    DoctorFinding(
                        severity: .warn,
                        code: "nfs-kernel",
                        message:
                            "Compose file uses NFS mounts. Guest kernel needs nfs in /proc/filesystems. "
                            + "Preferred install is NFS-capable: `container system kernel set --recommended` "
                            + "(CONTAINER_PREFERRED_KERNEL=nfs, default) or `make install-recommended-kernel` / "
                            + "`make install-nfs-kernel`. Set CONTAINER_PREFERRED_KERNEL=kata only for the "
                            + "historic Kata tarball (often omits nfs). See docs/volumes.md#nfs-mounts."
                    )
                )
            }

            // Exact aliases clash only within the same network (L3). Cross-network reuse is OK.
            // Keyed by network name → canonical name → first service that claimed it.
            var claimedByNetwork: [String: [String: String]] = [:]
            for service in services {
                let attachments: [(network: String, aliases: [String])] = {
                    if service.networks.isEmpty {
                        return [("default", [])]
                    }
                    return service.networks.map { ($0.name, $0.aliases) }
                }()
                for attachment in attachments {
                    var names = Set<String>()
                    names.insert(service.name.lowercased())
                    if let hostname = service.hostname {
                        names.insert(hostname.lowercased())
                    }
                    for alias in attachment.aliases {
                        names.insert(alias.lowercased())
                    }
                    var claimed = claimedByNetwork[attachment.network, default: [:]]
                    for name in names {
                        if let other = claimed[name], other != service.name {
                            findings.append(
                                DoctorFinding(
                                    severity: .warn,
                                    code: "alias-clash-in-file",
                                    message:
                                        "exact alias/hostname \"\(name)\" is claimed by services \(other) and "
                                        + "\(service.name) on network \"\(attachment.network)\". "
                                        + "Exact DNS names are unique per network (same name on different "
                                        + "networks is allowed; see docs/docker-job-catalog.md)."
                                )
                            )
                        } else if claimed[name] == nil {
                            claimed[name] = service.name
                        }
                    }
                    claimedByNetwork[attachment.network] = claimed
                }
            }

            findings.append(
                DoctorFinding(
                    severity: .info,
                    code: "vm-lifecycle",
                    message:
                        "Per-container VM dialect: exact aliases are unique per network (same alias on "
                        + "different networks is OK); CR network connect prefers virtio-net hotplug "
                        + "(VZ/disconnect still restart); devices are allowlist-only (F3); "
                        + "Swarm is F1b control-plane subset on the Engine bridge. "
                        + "See docs/docker-job-catalog.md."
                )
            )
            return findings
        }

        private static func rwNamedVolumeSources(service: Service, projectVolumes: [String: ProjectVolume]) -> [String] {
            var names: [String] = []
            for short in service.volumeShort {
                let parts = short.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                guard parts.count >= 2, !parts[0].contains("/") else { continue }
                let readOnly = parts.count > 2 && parts[2].split(separator: ",").contains("ro")
                guard !readOnly else { continue }
                if let pv = projectVolumes[parts[0]], pv.driver == "nfs" { continue }
                names.append(parts[0])
            }
            for mount in service.mounts {
                guard mountOption(mount, key: "type") == "volume" else { continue }
                if mount.split(separator: ",").contains("ro") { continue }
                if let source = mountOption(mount, key: "source") {
                    names.append(source)
                }
            }
            return names
        }

        private static func usesNFS(service: Service, projectVolumes: [String: ProjectVolume]) -> Bool {
            // After plan, NFS volumes are rewritten to `--mount type=nfs,...`.
            if service.mounts.contains(where: { mountOption($0, key: "type") == "nfs" }) {
                return true
            }
            // Short-form may still use the compose key or the resolved `project_name`.
            for short in service.volumeShort {
                let parts = short.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                guard parts.count >= 2, !parts[0].contains("/") else { continue }
                let key = parts[0]
                if projectVolumes[key]?.driver == "nfs" { return true }
                if projectVolumes.values.contains(where: { $0.name == key && $0.driver == "nfs" }) {
                    return true
                }
            }
            return false
        }

        private static func bindMountsDockerSock(service: Service) -> Bool {
            for short in service.volumeShort {
                let parts = short.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                if parts.contains(where: { $0 == "/var/run/docker.sock" || $0.hasSuffix("/docker.sock") }) {
                    return true
                }
            }
            for mount in service.mounts {
                if let source = mountOption(mount, key: "source"),
                    source == "/var/run/docker.sock" || source.hasSuffix("/docker.sock")
                {
                    return true
                }
            }
            return false
        }

        private static func mountOption(_ spec: String, key: String) -> String? {
            let prefix = "\(key)="
            for part in spec.split(separator: ",") {
                let s = String(part)
                if s.hasPrefix(prefix) {
                    return String(s.dropFirst(prefix.count))
                }
            }
            return nil
        }

        func containerName(for service: String) throws -> String {
            guard let svc = services.first(where: { $0.name == service }) else {
                throw ComposeError.invalid("unknown service \(service)")
            }
            return Self.instanceContainerName(svc, index: 1)
        }

        /// Planned container names for a service (one name, or `service-1..N` when replicas > 1).
        static func plannedContainerNames(_ service: Service) -> [String] {
            if service.replicas > 1 {
                return (1...service.replicas).map { instanceContainerName(service, index: $0) }
            }
            return [instanceContainerName(service, index: 1)]
        }

        static func instanceContainerName(_ service: Service, index: Int) -> String {
            if service.replicas > 1 {
                return "\(service.name)-\(index)"
            }
            return service.containerName ?? service.name
        }

        /// `up --force-recreate`: delete any existing containers for planned services first.
        func removeExisting() async throws {
            // Only this project's own containers: a same-named foreign container is not ours to delete.
            let owned = try projectContainerNames()
            warnUnownedPlannedContainers(owned: owned)
            for svc in services {
                for name in Self.plannedContainerNames(svc) where owned.contains(name) {
                    _ = try? runContainer(["delete", "-f", name])
                }
            }
        }

        /// `--remove-orphans`: delete project containers whose service is not declared in the file.
        func removeOrphans() async throws {
            let ids = try ComposeScope.orphanContainerIDs(
                listJSON: runContainer(["list", "-a", "--format", "json"]),
                project: project, declaredServices: declaredServices)
            for id in ids { _ = try? runContainer(["delete", "-f", id]) }
        }

        /// `down -v`: remove non-external named volumes declared by the project.
        func removeProjectVolumes() throws {
            let declared = Set(volumes.values.filter { !$0.external }.map(\.name))
            let names = try ComposeScope.removableVolumeNames(
                listJSON: runContainer(["volume", "list", "--format", "json"]), project: project, declared: declared)
            for name in names { _ = try? runContainer(["volume", "delete", name]) }
        }

        /// (name, id) of every container carrying this project's compose label. The single source of
        /// truth for "ours": anything that deletes or stops by name must stay inside this set.
        func projectContainerPairs() throws -> [(name: String, id: String)] {
            try ComposeScope.ownedContainers(
                listJSON: runContainer(["list", "-a", "--format", "json"]), project: project)
        }

        /// Names AND ids of this project's containers (see ``projectContainerPairs``).
        func projectContainerNames() throws -> Set<String> {
            Set(try projectContainerPairs().flatMap { [$0.name, $0.id] })
        }

        /// Planned names that exist as containers but are NOT labeled for this project (created by an
        /// older plugin, or by hand). Owned-only verbs deliberately leave them alone; say so instead
        /// of silently doing nothing.
        func warnUnownedPlannedContainers(owned: Set<String>) {
            guard let json = try? runContainer(["list", "-a", "--format", "json"]),
                let data = json.data(using: .utf8),
                let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
            else { return }
            let existing = Set(rows.compactMap { ($0["configuration"] as? [String: Any])?["name"] as? String })
            for svc in services {
                for name in Self.plannedContainerNames(svc) where existing.contains(name) && !owned.contains(name) {
                    FileHandle.standardError.write(
                        Data(
                            "warning: container '\(name)' exists but is not labeled for project '\(project)'; not touching it (delete it manually if it is yours)\n".utf8))
                }
            }
        }

        func projectContainerIDs() throws -> [String] {
            let json = try runContainer(["list", "-a", "--format", "json"])
            guard let data = json.data(using: .utf8),
                let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else {
                throw ComposeError.commandFailed("container list returned unparseable JSON")
            }
            var ids: [String] = []
            for row in rows {
                let labels = extractLabels(row)
                guard labels["com.docker.compose.project"] == project else { continue }
                if let cfg = row["configuration"] as? [String: Any], let cid = cfg["id"] as? String {
                    ids.append(cid)
                } else if let cid = row["id"] as? String {
                    ids.append(cid)
                }
            }
            // May be empty when labels are absent; callers (e.g. down) union planned names.
            return Array(Set(ids))
        }

        func build(only: Set<String>?, noCache: Bool = false) throws {
            for service in services {
                if let only, !only.contains(service.name) { continue }
                guard let build = service.build else { continue }
                var args = ["build"]
                if noCache { args.append("--no-cache") }
                let tag = build.tags.first ?? service.image
                args += ["-t", tag]
                if let dockerfile = build.dockerfile {
                    args += ["-f", dockerfile]
                }
                if let target = build.target {
                    args += ["--target", target]
                }
                for (k, v) in build.args.sorted(by: { $0.key < $1.key }) {
                    args += ["--build-arg", "\(k)=\(v)"]
                }
                args.append(build.context)
                _ = try runContainer(args)
            }
        }

        func pull(only: Set<String>?) throws {
            for service in services {
                if let only, !only.contains(service.name) { continue }
                // Skip only the auto-tagged local build image (`project_service:…`), not an
                // explicit registry `image:` that happens to share a prefix.
                if service.build != nil {
                    let auto = "\(project)_\(service.name)"
                    if service.image == auto || service.image.hasPrefix("\(auto):") {
                        continue
                    }
                }
                _ = try runContainer(["image", "pull", service.image])
            }
        }

        func up(detach: Bool, startContainers: Bool = true) async throws {
            try ensureNetworks()
            try ensureVolumes()
            try build(only: nil)

            for service in services {
                for dep in service.dependsOn {
                    switch dep.condition {
                    case .serviceHealthy:
                        try await waitUntilHealthy(try containerName(for: dep.service))
                    case .serviceCompletedSuccessfully:
                        // Dependency was started in foreground earlier; nothing to wait for.
                        break
                    case .serviceStarted:
                        break
                    }
                }
                // One-shot deps for `service_completed_successfully` must run in the
                // foreground: inspect does not persist exit codes once stopped, and
                // `container wait` rejects already-stopped containers. Independent
                // siblings are started before one-shots via topo order; dependents
                // always come after (Kahn sort).
                let awaitedByCompleted = services.contains { later in
                    later.dependsOn.contains {
                        $0.service == service.name && $0.condition == .serviceCompletedSuccessfully
                    }
                }
                let runDetached = detach && !awaitedByCompleted
                for index in 1...service.replicas {
                    var instance = service
                    instance.containerName = Self.instanceContainerName(service, index: index)
                    var args = try runArgs(
                        for: instance,
                        detach: runDetached,
                        commandOverride: nil,
                        oneOff: false,
                        containerNumber: index
                    )
                    if !startContainers, args.first == "run" {
                        args[0] = "create"
                        args.removeAll { $0 == "-d" }
                    }
                    _ = try runContainer(args)
                }
            }
        }

        func runOneOff(service: String, command: [String]) async throws {
            guard let svc = services.first(where: { $0.name == service }) else {
                throw ComposeError.invalid("unknown service \(service)")
            }
            try ensureNetworks()
            try ensureVolumes()
            if svc.build != nil {
                try build(only: [svc.name])
            }
            var oneOff = svc
            oneOff.containerName = "\(project)_\(svc.name)_run_\(UUID().uuidString.lowercased())"
            try runContainerStreaming(
                runArgs(for: oneOff, detach: false, commandOverride: command.isEmpty ? nil : command, oneOff: true))
        }

        func down(minimumStopTimeout: Int? = nil) async throws {
            // Prefer label selection; always tear down planned service names too.
            // Only containers carrying THIS project's label. Previously every planned service name was
            // added unconditionally, so `compose down` deleted any container that merely shared a
            // service's name. If the listing fails, do nothing rather than guess.
            let names = try projectContainerNames()
            warnUnownedPlannedContainers(owned: names)
            // `services` is topo-sorted (deps first); reverse so dependents stop first,
            // matching Compose. Extra labeled IDs (not in the file) follow alphabetically.
            var stopOrder: [String] = []
            var seen = Set<String>()
            for svc in services.reversed() {
                for name in Self.plannedContainerNames(svc) {
                    guard names.contains(name), seen.insert(name).inserted else { continue }
                    stopOrder.append(name)
                }
            }
            for name in names.sorted().reversed() where seen.insert(name).inserted {
                stopOrder.append(name)
            }
            // One batched `container stop -t N` for all names (per-service stops
            // serialized past budget; WordPress trio measured ~19s with `-t 1`).
            // N = max stop_grace_period so no service is SIGKILL'd early; shorter
            // services simply wait with the batch (intentional, not per-container -t).
            var stopTimeout = max(1, minimumStopTimeout ?? 1)
            for svc in services {
                guard let grace = svc.stopGracePeriod else { continue }
                let seconds = try ComposePlanner.parseDurationSeconds(
                    grace, field: "stop_grace_period", service: svc.name)
                stopTimeout = max(stopTimeout, Int(seconds))
            }
            if !stopOrder.isEmpty {
                var stopArgs = ["stop", "-t", "\(stopTimeout)"]
                stopArgs.append(contentsOf: stopOrder)
                _ = try? runContainer(stopArgs)
            }
            await withTaskGroup(of: Void.self) { group in
                for name in stopOrder {
                    group.addTask { _ = try? runContainer(["delete", "-f", name]) }
                }
                await group.waitForAll()
            }
            await withTaskGroup(of: Void.self) { group in
                for net in networks.values where !net.external {
                    group.addTask { _ = try? runContainer(["network", "delete", net.name]) }
                }
                group.addTask { _ = try? runContainer(["network", "delete", network]) }
                await group.waitForAll()
            }
        }

        private func ensureNetworks() throws {
            try ensureNetwork(named: network)
            for net in networks.values where !net.external {
                try ensureNetwork(named: net.name)
            }
        }

        private func ensureNetwork(named name: String) throws {
            do {
                _ = try runContainer(["network", "inspect", name])
            } catch {
                do {
                    _ = try runContainer(["network", "create", name])
                } catch let createError {
                    do {
                        _ = try runContainer(["network", "inspect", name])
                    } catch {
                        throw createError
                    }
                }
            }
        }

        private func ensureVolumes() throws {
            for vol in volumes.values {
                if vol.external { continue }
                if vol.driver == "nfs" {
                    // Materialized as --mount type=nfs at run time; no local volume create.
                    continue
                }
                do {
                    _ = try runContainer(["volume", "inspect", vol.name])
                } catch {
                    do {
                        _ = try runContainer(["volume", "create", "--label", "com.docker.compose.project=\(project)", vol.name])
                    } catch let createError {
                        // Concurrent compose up may have created it; succeed if inspect now works.
                        do {
                            _ = try runContainer(["volume", "inspect", vol.name])
                        } catch {
                            throw createError
                        }
                    }
                }
            }
        }

        private func runArgs(
            for service: Service,
            detach: Bool,
            commandOverride: [String]?,
            oneOff: Bool,
            containerNumber: Int = 1
        ) throws -> [String] {
            var args = ["run"]
            if detach { args.append("-d") }
            if oneOff { args.append("--rm") }

            let cname = service.containerName ?? service.name
            args += ["--name", cname]

            // Match Docker Compose: no `networks:` key → join the project default network.
            // Explicit `networks:` → only those networks (do not also force the default).
            // Container --name is the peer DNS/hosts key; when container_name differs from
            // the Compose service name, also publish the service name as an alias.
            // With replicas > 1, only instance 1 publishes the Compose service-name alias
            // (exact aliases are unique per network on the per-container VM model).
            let publishServiceAlias = cname != service.name && containerNumber == 1
            var networkArgs: [String] = []
            if service.networks.isEmpty {
                var spec = network
                if publishServiceAlias {
                    spec += ",alias=\(service.name)"
                }
                if containerNumber == 1, let hostname = service.hostname, hostname != service.name {
                    spec += ",alias=\(hostname)"
                }
                networkArgs.append(spec)
            } else {
                for extra in service.networks {
                    let resolved = networks[extra.name]?.name ?? "\(project)_\(extra.name)"
                    var spec = resolved
                    // Publish service/hostname aliases on every attached network so
                    // peers on non-first networks can still resolve the service.
                    if publishServiceAlias {
                        spec += ",alias=\(service.name)"
                    }
                    if containerNumber == 1, let hostname = service.hostname, hostname != service.name {
                        spec += ",alias=\(hostname)"
                    }
                    for alias in extra.aliases {
                        spec += ",alias=\(alias)"
                    }
                    networkArgs.append(spec)
                }
            }
            for n in networkArgs {
                args += ["--network", n]
            }

            if let hostname = service.hostname, !hostname.isEmpty {
                args += ["--hostname", hostname]
            }
            if let domain = service.domainname, !domain.isEmpty {
                args += ["--domainname", domain]
                // Keep label for inspect/config consumers that already key off it.
                args += ["--label", "com.docker.compose.domainname=\(domain)"]
            }
            if let grace = service.stopGracePeriod {
                let seconds = try ComposePlanner.parseDurationSeconds(
                    grace, field: "stop_grace_period", service: service.name)
                args += ["--stop-timeout", "\(seconds)"]
            }
            for cap in service.capAdd {
                args += ["--cap-add", cap]
            }
            for cap in service.capDrop {
                args += ["--cap-drop", cap]
            }
            for device in service.devices {
                args += ["--device", device]
            }

            for (key, value) in service.environment.sorted(by: { $0.key < $1.key }) {
                args += ["-e", "\(key)=\(value)"]
            }
            for port in service.ports {
                args += ["-p", port]
            }
            for volume in service.volumeShort {
                args += ["-v", volume]
            }
            for mount in service.mounts {
                args += ["--mount", mount]
            }
            for t in service.tmpfs {
                args += ["--tmpfs", t]
            }
            if let restart = service.restart {
                args += ["--restart", restart]
            }
            if let cwd = service.workingDir {
                args += ["-w", cwd]
            }
            if let user = service.user {
                args += ["-u", user]
            }
            if let shm = service.shmSize {
                args += ["--shm-size", shm]
            }
            // CLI `--entrypoint` is a single argv[0]; remaining list elements prepend command.
            var entryPrefix: [String] = []
            if let entry = service.entrypoint, !entry.isEmpty {
                args += ["--entrypoint", entry[0]]
                entryPrefix = Array(entry.dropFirst())
            }

            var labels = service.labels
            labels["com.docker.compose.project"] = project
            labels["com.docker.compose.service"] = service.name
            labels["com.docker.compose.container-number"] = "\(containerNumber)"
            if let domain = service.domainname {
                labels["com.docker.compose.domainname"] = domain
            }
            for (k, v) in labels.sorted(by: { $0.key < $1.key }) {
                args += ["-l", "\(k)=\(v)"]
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
            if let commandOverride {
                args += entryPrefix + commandOverride
            } else {
                args += entryPrefix + service.command
            }
            return args
        }
    }

    static func plan(fileURL: URL, project: String?, profiles: [String]) throws -> Plan {
        let data = try Data(contentsOf: fileURL)
        let rawText = String(data: data, encoding: .utf8) ?? ""
        let composeDir = fileURL.deletingLastPathComponent()
        let interpolationEnv = try composeInterpolationEnvironment(projectDir: composeDir)
        let text = try interpolateComposeString(rawText, env: interpolationEnv)
        guard let root = try Yams.load(yaml: text) as? [String: Any] else {
            throw ComposeError.invalid("compose file is not a mapping")
        }
        var unsupported: [(service: String?, key: String, reason: String)] = []

        let allowedTop: Set<String> = [
            "services", "networks", "volumes", "name", "version", "configs", "secrets",
        ]
        for key in root.keys where !allowedTop.contains(key) {
            if key.hasPrefix("x-") || key.hasPrefix("X-") { continue }
            unsupported.append((nil, key, "top-level key is not supported"))
        }

        let projectName =
            project
            ?? (root["name"] as? String)
            ?? composeDir.lastPathComponent
        let defaultNetwork = "\(projectName)_default"

        let activeProfiles = Set(profiles).union(profileEnv())

        let projectVolumes = try parseProjectVolumes(root["volumes"], project: projectName, unsupported: &unsupported)
        let projectNetworks = try parseProjectNetworks(root["networks"], project: projectName, unsupported: &unsupported)
        let configs = try parseFileArtifacts(root["configs"], kind: "configs", base: composeDir, unsupported: &unsupported)
        let secrets = try parseFileArtifacts(root["secrets"], kind: "secrets", base: composeDir, unsupported: &unsupported)

        guard let servicesMap = root["services"] as? [String: Any] else {
            throw ComposeError.invalid("compose file missing services")
        }

        var extendsCache: [String: [String: Any]] = [:]
        var extendsStack: [String] = []

        var services: [Service] = []
        for (name, raw) in servicesMap {
            guard let rawBody = raw as? [String: Any] else {
                throw ComposeError.invalid("service \(name) is not a mapping")
            }

            let body = try resolveExtends(
                serviceName: name,
                body: rawBody,
                fileURL: fileURL,
                servicesMap: servicesMap,
                stack: &extendsStack,
                cache: &extendsCache
            )

            let svcProfiles = stringList(body["profiles"])
            if !svcProfiles.isEmpty {
                let overlap = Set(svcProfiles).intersection(activeProfiles)
                if overlap.isEmpty { continue }
            }

            let allowed: Set<String> = [
                "image", "command", "entrypoint", "environment", "env_file", "ports", "volumes",
                "depends_on", "restart", "container_name", "healthcheck", "build", "labels",
                "working_dir", "user", "hostname", "domainname", "shm_size", "profiles",
                "tmpfs", "networks", "configs", "secrets", "stop_grace_period", "deploy",
                "cap_add", "cap_drop", "extends", "devices",
            ]
            for key in body.keys {
                if key.hasPrefix("x-") || key.hasPrefix("X-") { continue }
                if !allowed.contains(key) {
                    unsupported.append((name, key, "not implemented"))
                }
            }

            let build = try parseBuild(body["build"], service: name, base: composeDir)
            var image = body["image"] as? String
            if image == nil {
                guard build != nil else {
                    throw ComposeError.invalid("service \(name) requires image: or build:")
                }
                image = "\(projectName)_\(name):latest"
            }

            var environment = try parseEnvironment(body["environment"], service: name)
            if let envFiles = body["env_file"] {
                let files = try stringOrList(envFiles, field: "env_file", service: name)
                for f in files {
                    let url = composeDir.appendingPathComponent(f)
                    let fileEnv = try loadEnvFile(url)
                    for (k, v) in fileEnv where environment[k] == nil {
                        environment[k] = v
                    }
                }
            }

            let ports = try parsePorts(body["ports"], service: name)
            let (volumeShort, mounts) = try parseVolumes(
                body["volumes"],
                service: name,
                project: projectName,
                projectVolumes: projectVolumes,
                base: composeDir
            )
            var allMounts = mounts
            // File-based configs/secrets → bind mounts
            allMounts += try artifactMounts(body["configs"], artifacts: configs, service: name, defaultTarget: "/configs")
            allMounts += try artifactMounts(body["secrets"], artifacts: secrets, service: name, defaultTarget: "/run/secrets")

            let tmpfs = try parseTmpfs(body["tmpfs"], service: name)
            let dependsOn = try parseDependsOn(body["depends_on"], service: name)
            let healthcheck = try parseHealthcheck(body["healthcheck"], service: name)
            let labels = try parseLabels(body["labels"], service: name)
            let networks = try parseServiceNetworks(body["networks"], service: name)
            let command = try parseCommand(body["command"], service: name)
            let entrypoint = try parseEntrypoint(body["entrypoint"], service: name)
            let (replicas, deployRestart) = try parseDeploySubset(body["deploy"], service: name)
            var restart = body["restart"] as? String
            if restart == nil {
                restart = deployRestart
            }

            var resolvedImage = image!
            if let build, body["image"] == nil {
                resolvedImage = build.tags.first ?? "\(projectName)_\(name):latest"
            }

            services.append(
                Service(
                    name: name,
                    containerName: body["container_name"] as? String,
                    image: resolvedImage,
                    build: build.map { spec in
                        var s = spec
                        if s.tags.isEmpty { s.tags = [resolvedImage] }
                        return s
                    },
                    command: command,
                    entrypoint: entrypoint,
                    environment: environment,
                    ports: ports,
                    volumeShort: volumeShort,
                    mounts: allMounts,
                    tmpfs: tmpfs,
                    dependsOn: dependsOn,
                    restart: restart,
                    healthcheck: healthcheck,
                    labels: labels,
                    workingDir: body["working_dir"] as? String,
                    user: stringifyScalar(body["user"]),
                    hostname: body["hostname"] as? String,
                    domainname: body["domainname"] as? String,
                    shmSize: stringifyScalar(body["shm_size"]),
                    profiles: svcProfiles,
                    networks: networks,
                    stopGracePeriod: stringifyScalar(body["stop_grace_period"]),
                    capAdd: stringList(body["cap_add"]),
                    capDrop: stringList(body["cap_drop"]),
                    devices: try parseComposeDevices(body["devices"], service: name),
                    replicas: replicas
                ))
        }

        services = try topoSortServices(services)

        return Plan(
            project: projectName,
            network: defaultNetwork,
            composeFileDir: composeDir,
            services: services,
            volumes: projectVolumes,
            networks: projectNetworks,
            unsupported: unsupported,
            declaredServices: Set(servicesMap.keys)
        )
    }

    private static func profileEnv() -> Set<String> {
        let raw = ProcessInfo.processInfo.environment["COMPOSE_PROFILES"] ?? ""
        return Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    /// Resolve `extends` (same file or `file:` relative to the compose file directory).
    private static func resolveExtends(
        serviceName: String,
        body: [String: Any],
        fileURL: URL,
        servicesMap: [String: Any],
        stack: inout [String],
        cache: inout [String: [String: Any]]
    ) throws -> [String: Any] {
        let cacheKey = "\(fileURL.path)::\(serviceName)"
        if let cached = cache[cacheKey] {
            return cached
        }
        if stack.contains(cacheKey) {
            throw ComposeError.invalid("service \(serviceName): extends cycle detected")
        }
        stack.append(cacheKey)
        defer { _ = stack.popLast() }

        guard let extendsRaw = body["extends"] else {
            cache[cacheKey] = body
            return body
        }

        let (parentService, parentFileRel) = try parseExtendsSpec(extendsRaw, service: serviceName)
        let parentFileURL: URL
        let parentServicesMap: [String: Any]
        if let rel = parentFileRel {
            parentFileURL = fileURL.deletingLastPathComponent().appendingPathComponent(rel).standardizedFileURL
            parentServicesMap = try loadComposeServicesMap(fileURL: parentFileURL)
        } else {
            parentFileURL = fileURL
            parentServicesMap = servicesMap
        }
        guard let parentRaw = parentServicesMap[parentService] as? [String: Any] else {
            let whereFile = parentFileRel.map { " in \($0)" } ?? ""
            throw ComposeError.invalid(
                "service \(serviceName): extends unknown service \"\(parentService)\"\(whereFile)"
            )
        }
        let resolvedParent = try resolveExtends(
            serviceName: parentService,
            body: parentRaw,
            fileURL: parentFileURL,
            servicesMap: parentServicesMap,
            stack: &stack,
            cache: &cache
        )
        var child = body
        child.removeValue(forKey: "extends")
        let merged = deepMergeComposeService(parent: resolvedParent, child: child)
        cache[cacheKey] = merged
        return merged
    }

    /// Kahn topological sort: dependencies before dependents. Cycles fail closed.
    private static func topoSortServices(_ services: [Service]) throws -> [Service] {
        var byName = Dictionary(uniqueKeysWithValues: services.map { ($0.name, $0) })
        var indegree: [String: Int] = Dictionary(uniqueKeysWithValues: services.map { ($0.name, 0) })
        var adjacency: [String: [String]] = Dictionary(uniqueKeysWithValues: services.map { ($0.name, []) })
        for service in services {
            for dep in service.dependsOn {
                guard byName[dep.service] != nil else {
                    throw ComposeError.invalid("service \(service.name): depends_on unknown service \"\(dep.service)\"")
                }
                adjacency[dep.service, default: []].append(service.name)
                indegree[service.name, default: 0] += 1
            }
        }
        var queue = indegree.filter { $0.value == 0 }.map(\.key).sorted()
        var ordered: [Service] = []
        while !queue.isEmpty {
            let name = queue.removeFirst()
            guard let service = byName.removeValue(forKey: name) else { continue }
            ordered.append(service)
            for next in adjacency[name, default: []].sorted() {
                indegree[next, default: 0] -= 1
                if indegree[next] == 0 {
                    let idx = queue.firstIndex { $0 > next } ?? queue.endIndex
                    queue.insert(next, at: idx)
                }
            }
        }
        guard ordered.count == services.count else {
            throw ComposeError.invalid("services have a depends_on cycle")
        }
        return ordered
    }
}

// MARK: - Parsing helpers

private func parseExtendsSpec(_ raw: Any, service: String) throws -> (service: String, file: String?) {
    if let name = raw as? String, !name.isEmpty {
        return (name, nil)
    }
    guard let body = raw as? [String: Any] else {
        throw ComposeError.invalid("service \(service): extends must be a mapping or service name")
    }
    guard let parent = body["service"] as? String, !parent.isEmpty else {
        throw ComposeError.invalid("service \(service): extends requires service:")
    }
    let file = body["file"] as? String
    return (parent, file)
}

private func loadComposeServicesMap(fileURL: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: fileURL)
    let rawText = String(data: data, encoding: .utf8) ?? ""
    let composeDir = fileURL.deletingLastPathComponent()
    let interpolationEnv = try composeInterpolationEnvironment(projectDir: composeDir)
    let text = try interpolateComposeString(rawText, env: interpolationEnv)
    guard let root = try Yams.load(yaml: text) as? [String: Any] else {
        throw ComposeError.invalid("extends file \(fileURL.lastPathComponent) is not a mapping")
    }
    guard let services = root["services"] as? [String: Any] else {
        throw ComposeError.invalid("extends file \(fileURL.lastPathComponent) missing services")
    }
    return services
}

/// Deep-merge a parent service mapping with a child: scalars → child wins; maps recurse;
/// `ports` / `volumes` / list-shaped `environment` concatenate; env key conflicts → child wins.
private func deepMergeComposeService(parent: [String: Any], child: [String: Any]) -> [String: Any] {
    var result = parent
    result.removeValue(forKey: "extends")
    for (key, childVal) in child {
        if key == "extends" { continue }
        guard let parentVal = result[key] else {
            result[key] = childVal
            continue
        }
        switch key {
        case "ports", "volumes", "tmpfs", "cap_add", "cap_drop", "configs", "secrets", "env_file",
            "dns", "dns_search", "extra_hosts", "devices":
            result[key] = concatComposeLists(parentVal, childVal)
        case "environment":
            result[key] = mergeComposeEnvironment(parent: parentVal, child: childVal)
        case "labels":
            result[key] = mergeComposeStringMap(parent: parentVal, child: childVal)
        default:
            if let parentMap = parentVal as? [String: Any], let childMap = childVal as? [String: Any] {
                result[key] = deepMergeComposeService(parent: parentMap, child: childMap)
            } else {
                result[key] = childVal
            }
        }
    }
    return result
}

private func concatComposeLists(_ parent: Any, _ child: Any) -> [Any] {
    asComposeList(parent) + asComposeList(child)
}

private func asComposeList(_ raw: Any) -> [Any] {
    if let list = raw as? [Any] { return list }
    if raw is NSNull { return [] }
    return [raw]
}

private func mergeComposeEnvironment(parent: Any, child: Any) -> [String: Any] {
    var map = composeEnvironmentToMap(parent)
    for (k, v) in composeEnvironmentToMap(child) {
        map[k] = v
    }
    return map
}

private func mergeComposeStringMap(parent: Any, child: Any) -> [String: Any] {
    var map = composeEnvironmentToMap(parent)
    for (k, v) in composeEnvironmentToMap(child) {
        map[k] = v
    }
    return map
}

private func composeEnvironmentToMap(_ raw: Any) -> [String: Any] {
    if let map = asStringKeyedMap(raw) {
        return map
    }
    if let list = raw as? [Any] {
        var out: [String: Any] = [:]
        for item in list {
            guard let s = item as? String else { continue }
            let parts = s.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard let key = parts.first, !key.isEmpty else { continue }
            out[key] = parts.count == 1 ? NSNull() : parts[1]
        }
        return out
    }
    return [:]
}

/// Interim `deploy` subset: `replicas` (cap 3) and `restart_policy.condition`.
private func parseDeploySubset(_ raw: Any?, service: String) throws -> (replicas: Int, restart: String?) {
    guard let raw else { return (1, nil) }
    guard let body = raw as? [String: Any] else {
        throw ComposeError.invalid("service \(service): deploy must be a mapping")
    }
    var replicas = 1
    if let n = body["replicas"] as? Int {
        replicas = n
    } else if let n = body["replicas"] as? UInt64 {
        replicas = Int(n)
    } else if let s = body["replicas"] as? String, let n = Int(s) {
        replicas = n
    } else if body["replicas"] != nil {
        throw ComposeError.invalid("service \(service): deploy.replicas must be an integer")
    }
    if replicas < 1 {
        FileHandle.standardError.write(
            Data("WARN: service \(service): deploy.replicas=\(replicas) treated as 1\n".utf8))
        replicas = 1
    }
    if replicas > 3 {
        FileHandle.standardError.write(
            Data(
                "WARN: service \(service): deploy.replicas=\(replicas) capped at 3; creating service-1..3\n"
                    .utf8))
        replicas = 3
    }

    var restart: String?
    if let policy = body["restart_policy"] as? [String: Any],
        let condition = policy["condition"] as? String
    {
        restart = mapDeployRestartCondition(condition)
    }
    return (replicas, restart)
}

private func mapDeployRestartCondition(_ condition: String) -> String {
    switch condition {
    case "none":
        return "no"
    case "on-failure":
        return "on-failure"
    case "any":
        return "always"
    default:
        return condition
    }
}

private func parseProjectVolumes(
    _ raw: Any?,
    project: String,
    unsupported: inout [(service: String?, key: String, reason: String)]
) throws -> [String: ComposePlanner.ProjectVolume] {
    guard let raw else { return [:] }
    guard let map = raw as? [String: Any] else {
        throw ComposeError.invalid("volumes must be a mapping")
    }
    var result: [String: ComposePlanner.ProjectVolume] = [:]
    for (name, value) in map {
        let fullName = "\(project)_\(name)"
        if value is NSNull {
            result[name] = .init(name: fullName, driver: "local", driverOpts: [:], external: false)
            continue
        }
        // Compose requires null or a mapping; a bare string is invalid.
        if value is String {
            throw ComposeError.invalid("volumes.\(name) must be null or a mapping")
        }
        guard let body = value as? [String: Any] else {
            throw ComposeError.invalid("volumes.\(name) must be a mapping")
        }
        let external: Bool
        if let b = body["external"] as? Bool {
            external = b
        } else if let m = body["external"] as? [String: Any], let n = m["name"] as? String {
            result[name] = .init(name: n, driver: "local", driverOpts: [:], external: true)
            continue
        } else {
            external = false
        }
        let driver = (body["driver"] as? String) ?? "local"
        var opts: [String: String] = [:]
        if let rawOpts = body["driver_opts"] as? [String: Any] {
            for (k, v) in rawOpts {
                opts[k] = stringifyScalar(v) ?? ""
            }
        }
        if driver != "local", driver != "nfs" {
            unsupported.append((nil, "volumes.\(name).driver", "only local and nfs drivers are supported"))
        }
        let volName = (body["name"] as? String) ?? fullName
        result[name] = .init(name: volName, driver: driver, driverOpts: opts, external: external)
    }
    return result
}

private func parseProjectNetworks(
    _ raw: Any?,
    project: String,
    unsupported: inout [(service: String?, key: String, reason: String)]
) throws -> [String: ComposePlanner.ProjectNetwork] {
    guard let raw else { return [:] }
    guard let map = raw as? [String: Any] else {
        throw ComposeError.invalid("networks must be a mapping")
    }
    var result: [String: ComposePlanner.ProjectNetwork] = [:]
    for (name, value) in map {
        let fullName = "\(project)_\(name)"
        if value is NSNull {
            result[name] = .init(name: fullName, driver: nil, external: false, aliases: [])
            continue
        }
        guard let body = value as? [String: Any] else {
            throw ComposeError.invalid("networks.\(name) must be a mapping")
        }
        let external = (body["external"] as? Bool) ?? false
        let netName = (body["name"] as? String) ?? fullName
        if body["ipam"] != nil {
            unsupported.append((nil, "networks.\(name).ipam", "ipam is not implemented"))
        }
        result[name] = .init(name: netName, driver: body["driver"] as? String, external: external, aliases: [])
    }
    return result
}

private struct FileArtifact {
    var name: String
    var file: URL
}

private func parseFileArtifacts(
    _ raw: Any?,
    kind: String,
    base: URL,
    unsupported: inout [(service: String?, key: String, reason: String)]
) throws -> [String: FileArtifact] {
    guard let raw else { return [:] }
    guard let map = raw as? [String: Any] else {
        throw ComposeError.invalid("\(kind) must be a mapping")
    }
    var result: [String: FileArtifact] = [:]
    for (name, value) in map {
        guard let body = value as? [String: Any] else {
            throw ComposeError.invalid("\(kind).\(name) must be a mapping")
        }
        if let file = body["file"] as? String {
            result[name] = FileArtifact(name: name, file: base.appendingPathComponent(file))
        } else if body["external"] != nil {
            unsupported.append((nil, "\(kind).\(name)", "external \(kind) are not supported yet"))
        } else {
            unsupported.append((nil, "\(kind).\(name)", "only file-based \(kind) are supported"))
        }
    }
    return result
}

private func artifactMounts(
    _ raw: Any?,
    artifacts: [String: FileArtifact],
    service: String,
    defaultTarget: String
) throws -> [String] {
    guard let raw else { return [] }
    var refs: [(name: String, target: String)] = []
    guard let list = raw as? [Any] else {
        throw ComposeError.invalid("service \(service): configs/secrets must be a list")
    }
    for item in list {
        if let s = item as? String {
            refs.append((s, "\(defaultTarget)/\(s)"))
        } else if let m = item as? [String: Any], let source = m["source"] as? String {
            let target = (m["target"] as? String) ?? "\(defaultTarget)/\(source)"
            refs.append((source, target))
        } else {
            throw ComposeError.invalid("service \(service): invalid configs/secrets entry")
        }
    }
    var mounts: [String] = []
    for ref in refs {
        guard let art = artifacts[ref.name] else {
            throw ComposeError.invalid("service \(service): unknown config/secret \(ref.name)")
        }
        mounts.append("type=bind,source=\(art.file.path),destination=\(ref.target),ro")
    }
    return mounts
}

private func parseBuild(_ raw: Any?, service: String, base: URL) throws -> ComposePlanner.BuildSpec? {
    guard let raw else { return nil }
    if let context = raw as? String {
        let ctx = base.appendingPathComponent(context).path
        return .init(context: ctx, dockerfile: nil, target: nil, args: [:], tags: [])
    }
    guard let body = raw as? [String: Any] else {
        throw ComposeError.invalid("service \(service): build must be a string or mapping")
    }
    let contextRel = (body["context"] as? String) ?? "."
    let context = base.appendingPathComponent(contextRel).path
    var dockerfile: String? = body["dockerfile"] as? String
    if let df = dockerfile {
        dockerfile = base.appendingPathComponent(contextRel).appendingPathComponent(df).path
    }
    var args: [String: String] = [:]
    if let rawArgs = body["args"] as? [String: Any] {
        for (k, v) in rawArgs {
            args[k] = stringifyScalar(v) ?? ""
        }
    }
    return .init(
        context: context,
        dockerfile: dockerfile,
        target: body["target"] as? String,
        args: args,
        tags: []
    )
}

private func parsePorts(_ raw: Any?, service: String) throws -> [String] {
    guard let raw else { return [] }
    guard let list = raw as? [Any] else {
        throw ComposeError.invalid("service \(service): ports must be a list")
    }
    var result: [String] = []
    for (idx, item) in list.enumerated() {
        if let s = item as? String {
            result.append(s)
            continue
        }
        if let n = item as? Int {
            result.append("\(n)")
            continue
        }
        guard let m = item as? [String: Any] else {
            throw ComposeError.invalid("service \(service): ports[\(idx)] must be a string or mapping")
        }
        guard let target = m["target"] else {
            throw ComposeError.invalid("service \(service): ports[\(idx)] long-form requires target")
        }
        let targetStr = stringifyScalar(target) ?? ""
        let published = stringifyScalar(m["published"]) ?? targetStr
        let proto = (m["protocol"] as? String) ?? "tcp"
        if let hostIP = m["host_ip"] as? String, !hostIP.isEmpty {
            result.append("\(hostIP):\(published):\(targetStr)/\(proto)")
        } else {
            result.append("\(published):\(targetStr)/\(proto)")
        }
    }
    return result
}

private func parseVolumes(
    _ raw: Any?,
    service: String,
    project: String,
    projectVolumes: [String: ComposePlanner.ProjectVolume],
    base: URL
) throws -> (short: [String], mounts: [String]) {
    guard let raw else { return ([], []) }
    guard let list = raw as? [Any] else {
        throw ComposeError.invalid("service \(service): volumes must be a list")
    }
    var short: [String] = []
    var mounts: [String] = []
    for (idx, item) in list.enumerated() {
        if let s = item as? String {
            // Named volume short form: name:/path → project_name:/path when declared
            let parts = s.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            if parts.count >= 2, !parts[0].contains("/"), parts[0] != ".", parts[0] != ".." {
                let volKey = parts[0]
                if let pv = projectVolumes[volKey] {
                    if pv.driver == "nfs" {
                        mounts.append(try nfsMountSpec(volume: pv, destination: parts[1], readOnly: parts.count > 2 && parts[2].contains("ro")))
                    } else {
                        var rewritten = "\(pv.name):\(parts[1])"
                        if parts.count > 2 { rewritten += ":\(parts[2])" }
                        short.append(rewritten)
                    }
                } else {
                    // Compose auto-creates undeclared named volumes as project_key
                    // (same prefix as declared local volumes).
                    var rewritten = "\(project)_\(volKey):\(parts[1])"
                    if parts.count > 2 { rewritten += ":\(parts[2])" }
                    short.append(rewritten)
                }
            } else if parts.count >= 2, parts[0].contains("/") || parts[0] == "." || parts[0].hasPrefix("./") {
                // Relative bind → absolute for reliability
                let src = base.appendingPathComponent(parts[0]).path
                var rewritten = "\(src):\(parts[1])"
                if parts.count > 2 { rewritten += ":\(parts[2])" }
                short.append(rewritten)
            } else {
                short.append(s)
            }
            continue
        }
        guard let m = item as? [String: Any] else {
            throw ComposeError.invalid("service \(service): volumes[\(idx)] must be a string or mapping")
        }
        let type = (m["type"] as? String) ?? "volume"
        let target = (m["target"] as? String) ?? (m["destination"] as? String)
        guard let target, !target.isEmpty else {
            throw ComposeError.invalid("service \(service): volumes[\(idx)] requires target")
        }
        let readOnly = (m["read_only"] as? Bool) ?? false
        switch type {
        case "bind":
            guard let source = m["source"] as? String else {
                throw ComposeError.invalid("service \(service): bind volume requires source")
            }
            let abs = source.hasPrefix("/") ? source : base.appendingPathComponent(source).path
            var spec = "type=bind,source=\(abs),destination=\(target)"
            if readOnly { spec += ",ro" }
            mounts.append(spec)
        case "volume":
            guard let source = m["source"] as? String else {
                // anonymous
                mounts.append("type=volume,destination=\(target)")
                break
            }
            if let pv = projectVolumes[source] {
                if pv.driver == "nfs" {
                    mounts.append(try nfsMountSpec(volume: pv, destination: target, readOnly: readOnly))
                } else {
                    var spec = "type=volume,source=\(pv.name),destination=\(target)"
                    if readOnly { spec += ",ro" }
                    mounts.append(spec)
                }
            } else {
                // Undeclared named volume → project-prefixed, matching Compose.
                var spec = "type=volume,source=\(project)_\(source),destination=\(target)"
                if readOnly { spec += ",ro" }
                mounts.append(spec)
            }
        case "tmpfs":
            var spec = "type=tmpfs,destination=\(target)"
            if let tmpfs = m["tmpfs"] as? [String: Any], let size = stringifyScalar(tmpfs["size"]) {
                spec += ",size=\(size)"
            }
            mounts.append(spec)
        case "nfs":
            guard let source = m["source"] as? String else {
                throw ComposeError.invalid("service \(service): nfs volume requires source")
            }
            var spec = "type=nfs,source=\(source),destination=\(target)"
            if readOnly { spec += ",ro" }
            if let opts = m["o"] as? String {
                for part in opts.split(separator: ",") {
                    spec += ",\(part)"
                }
            }
            if let volume = m["volume"] as? [String: Any], let o = volume["o"] as? String {
                for part in o.split(separator: ",") {
                    spec += ",\(part)"
                }
            }
            // Common compose practice: addr under driver-like keys
            if let addr = m["addr"] as? String {
                spec += ",addr=\(addr)"
            }
            mounts.append(spec)
        default:
            throw ComposeError.invalid("service \(service): unsupported volume type \(type)")
        }
    }
    return (short, mounts)
}

private func nfsMountSpec(volume: ComposePlanner.ProjectVolume, destination: String, readOnly: Bool) throws -> String {
    let opts = volume.driverOpts
    let device = opts["device"] ?? opts["source"] ?? ""
    guard !device.isEmpty else {
        throw ComposeError.invalid("nfs volume \(volume.name) requires driver_opts.device")
    }
    // device may be ":/export" or "server:/export"
    var source = device
    var addrFromDevice: String?
    if let idx = device.firstIndex(of: ":"), device[device.startIndex] != ":" {
        addrFromDevice = String(device[..<idx])
        source = String(device[device.index(after: idx)...])
    } else if device.hasPrefix(":") {
        source = String(device.dropFirst())
    }
    var spec = "type=nfs,source=\(source),destination=\(destination)"
    var seen = Set<String>()
    func appendOpt(_ raw: String) {
        let p = raw.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return }
        let key = p.split(separator: "=", maxSplits: 1).first.map(String.init) ?? p
        if seen.contains(key) { return }
        seen.insert(key)
        spec += ",\(p)"
    }
    if readOnly { appendOpt("ro") }
    if let o = opts["o"] {
        for part in o.split(separator: ",") {
            appendOpt(String(part))
        }
    }
    if let addr = addrFromDevice {
        appendOpt("addr=\(addr)")
    }
    return spec
}

private func parseTmpfs(_ raw: Any?, service: String) throws -> [String] {
    guard let raw else { return [] }
    if let s = raw as? String { return [s] }
    if let list = raw as? [String] { return list }
    throw ComposeError.invalid("service \(service): tmpfs must be a string or list")
}

private func parseServiceNetworks(_ raw: Any?, service: String) throws -> [ComposePlanner.ServiceNetwork] {
    guard let raw else { return [] }
    if let list = raw as? [String] {
        return list.map { .init(name: $0, aliases: []) }
    }
    guard let map = raw as? [String: Any] else {
        throw ComposeError.invalid("service \(service): networks must be a list or mapping")
    }
    var result: [ComposePlanner.ServiceNetwork] = []
    for (name, value) in map {
        if value is NSNull {
            result.append(.init(name: name, aliases: []))
            continue
        }
        guard let body = value as? [String: Any] else {
            throw ComposeError.invalid("service \(service): networks.\(name) must be a mapping")
        }
        let aliases = stringList(body["aliases"])
        result.append(.init(name: name, aliases: aliases))
    }
    return result.sorted { $0.name < $1.name }
}

private func parseDependsOn(_ raw: Any?, service: String) throws -> [ComposePlanner.Dependency] {
    guard let raw else { return [] }
    if let deps = raw as? [String] {
        return deps.map { .init(service: $0, condition: .serviceStarted) }
    }
    guard let deps = raw as? [String: Any] else {
        throw ComposeError.invalid("service \(service): depends_on must be a list or mapping")
    }
    var result: [ComposePlanner.Dependency] = []
    for (depName, value) in deps {
        // Mapping form `db: null` (or a bare string) means service_started.
        if value is NSNull || value is String {
            result.append(.init(service: depName, condition: .serviceStarted))
            continue
        }
        guard let body = value as? [String: Any] else {
            throw ComposeError.invalid("service \(service): depends_on.\(depName) must be a mapping")
        }
        let conditionRaw = (body["condition"] as? String) ?? ComposePlanner.DependCondition.serviceStarted.rawValue
        guard let condition = ComposePlanner.DependCondition(rawValue: conditionRaw) else {
            throw ComposeError.invalid(
                "service \(service): unsupported depends_on condition \"\(conditionRaw)\""
            )
        }
        result.append(.init(service: depName, condition: condition))
    }
    return result.sorted { $0.service < $1.service }
}

private func parseHealthcheck(_ raw: Any?, service: String) throws -> ComposePlanner.HealthcheckSpec? {
    guard let raw else { return nil }
    guard let body = raw as? [String: Any] else {
        throw ComposeError.invalid("service \(service): healthcheck must be a mapping")
    }
    if let disable = body["disable"] as? Bool, disable {
        return nil
    }
    let test: String
    if let argvAny = body["test"] as? [Any], !argvAny.isEmpty {
        var argv: [String] = []
        for (idx, el) in argvAny.enumerated() {
            guard let s = el as? String else {
                throw ComposeError.invalid("service \(service): healthcheck.test[\(idx)] must be a string")
            }
            argv.append(s)
        }
        let data = try JSONSerialization.data(withJSONObject: argv)
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw ComposeError.invalid("service \(service): healthcheck.test could not be encoded")
        }
        test = encoded
    } else if let shell = body["test"] as? String, !shell.isEmpty {
        test = shell
    } else {
        // Docker Compose: no `test` (common with `disable: false`) means "use the image
        // HEALTHCHECK". We cannot read image config here, so omit an engine override.
        return nil
    }
    return .init(
        test: test,
        intervalSeconds: try optionalDurationSeconds(body["interval"], field: "interval", service: service),
        timeoutSeconds: try optionalDurationSeconds(body["timeout"], field: "timeout", service: service),
        startPeriodSeconds: try optionalDurationSeconds(body["start_period"], field: "start_period", service: service),
        retries: try optionalUInt64(body["retries"], field: "retries", service: service)
    )
}

private func parseEnvironment(_ raw: Any?, service: String) throws -> [String: String] {
    guard let raw else { return [:] }
    var environment: [String: String] = [:]
    if let envMap = asStringKeyedMap(raw) {
        for (k, v) in envMap {
            guard !k.isEmpty else {
                throw ComposeError.invalid("service \(service): environment keys must be non-empty")
            }
            if v is NSNull {
                environment[k] = ""
            } else if let s = stringifyScalar(v) {
                environment[k] = s
            } else {
                throw ComposeError.invalid("service \(service): environment.\(k) must be a scalar or null")
            }
        }
    } else if let envList = raw as? [String] {
        for item in envList {
            let parts = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard let key = parts.first, !key.isEmpty else {
                throw ComposeError.invalid("service \(service): environment list entries must have a non-empty key")
            }
            // Compose list form `FOO` (no `=`) resolves from the host environment.
            environment[key] =
                parts.count == 1
                ? (ProcessInfo.processInfo.environment[key] ?? "")
                : parts[1]
        }
    } else if let envList = raw as? [Any] {
        for item in envList {
            guard let s = item as? String else {
                throw ComposeError.invalid("service \(service): environment list entries must be strings")
            }
            let parts = s.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard let key = parts.first, !key.isEmpty else {
                throw ComposeError.invalid("service \(service): environment list entries must have a non-empty key")
            }
            environment[key] =
                parts.count == 1
                ? (ProcessInfo.processInfo.environment[key] ?? "")
                : parts[1]
        }
    } else {
        throw ComposeError.invalid("service \(service): environment must be a mapping or list")
    }
    return environment
}

/// Yams maps often arrive as NSDictionary / [AnyHashable: Any], not [String: Any].
private func asStringKeyedMap(_ raw: Any) -> [String: Any]? {
    if let map = raw as? [String: Any] {
        return map
    }
    if let map = raw as? [AnyHashable: Any] {
        var out: [String: Any] = [:]
        for (k, v) in map {
            guard let key = k as? String else { return nil }
            out[key] = v
        }
        return out
    }
    return nil
}

private func parseLabels(_ raw: Any?, service: String) throws -> [String: String] {
    guard let raw else { return [:] }
    if let map = raw as? [String: Any] {
        var out: [String: String] = [:]
        for (k, v) in map {
            out[k] = stringifyScalar(v) ?? ""
        }
        return out
    }
    if let list = raw as? [String] {
        var out: [String: String] = [:]
        for item in list {
            let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
            guard let key = parts.first else { continue }
            out[key] = parts.count > 1 ? parts[1] : ""
        }
        return out
    }
    throw ComposeError.invalid("service \(service): labels must be a mapping or list")
}

private func parseCommand(_ raw: Any?, service: String) throws -> [String] {
    guard let raw else { return [] }
    if let cmdAny = raw as? [Any] {
        var parsed: [String] = []
        for (idx, el) in cmdAny.enumerated() {
            guard let s = stringifyScalar(el) else {
                throw ComposeError.invalid("service \(service): command[\(idx)] must be a string or number")
            }
            parsed.append(s)
        }
        return parsed
    }
    if let cmd = raw as? String {
        return ["sh", "-c", cmd]
    }
    throw ComposeError.invalid("service \(service): command must be a string or list of strings")
}

private func parseEntrypoint(_ raw: Any?, service: String) throws -> [String]? {
    guard let raw else { return nil }
    if let s = raw as? String { return [s] }
    if let list = raw as? [Any] {
        return try list.enumerated().map { idx, el in
            guard let s = stringifyScalar(el) else {
                throw ComposeError.invalid("service \(service): entrypoint[\(idx)] must be a scalar")
            }
            return s
        }
    }
    throw ComposeError.invalid("service \(service): entrypoint must be a string or list")
}

private func loadEnvFile(_ url: URL) throws -> [String: String] {
    let text = try String(contentsOf: url, encoding: .utf8)
    var out: [String: String] = [:]
    for line in text.split(whereSeparator: \.isNewline) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
        let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
        guard let key = parts.first, !key.isEmpty else { continue }
        var value = parts.count > 1 ? parts[1] : ""
        // Strip matching single/double quotes (Docker Compose .env style).
        if value.count >= 2 {
            let first = value.first!
            let last = value.last!
            if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                value = String(value.dropFirst().dropLast())
            }
        }
        out[key] = value
    }
    return out
}

/// Build the env map used for Compose `${VAR}` substitution: project `.env`, then
/// process environment overrides (Docker Compose precedence).
func composeInterpolationEnvironment(projectDir: URL) throws -> [String: String] {
    var env: [String: String] = [:]
    let dotenv = projectDir.appendingPathComponent(".env")
    if FileManager.default.fileExists(atPath: dotenv.path) {
        env.merge(try loadEnvFile(dotenv)) { _, new in new }
    }
    for (key, value) in ProcessInfo.processInfo.environment {
        env[key] = value
    }
    return env
}

/// Docker Compose–shaped string interpolation for compose YAML text.
/// Supports `$VAR`, `${VAR}`, `${VAR:-default}`, `${VAR-default}`, `${VAR:?err}`,
/// `${VAR?err}`, and `$$` → `$`.
func interpolateComposeString(_ input: String, env: [String: String]) throws -> String {
    var out = String()
    out.reserveCapacity(input.count)
    var i = input.startIndex
    while i < input.endIndex {
        let ch = input[i]
        if ch != "$" {
            out.append(ch)
            i = input.index(after: i)
            continue
        }
        let afterDollar = input.index(after: i)
        guard afterDollar < input.endIndex else {
            out.append("$")
            break
        }
        if input[afterDollar] == "$" {
            out.append("$")
            i = input.index(after: afterDollar)
            continue
        }
        if input[afterDollar] == "{" {
            // ${...}
            guard let close = input[afterDollar...].firstIndex(of: "}") else {
                throw ComposeError.invalid("compose interpolation: unclosed ${...}")
            }
            let innerStart = input.index(after: afterDollar)
            let inner = String(input[innerStart..<close])
            out.append(try resolveComposeInterpolation(inner: inner, env: env))
            i = input.index(after: close)
            continue
        }
        // $VAR
        var nameEnd = afterDollar
        if input[nameEnd].isLetter || input[nameEnd] == "_" {
            nameEnd = input.index(after: nameEnd)
            while nameEnd < input.endIndex {
                let c = input[nameEnd]
                guard c.isLetter || c.isNumber || c == "_" else {
                    break
                }
                nameEnd = input.index(after: nameEnd)
            }
            let name = String(input[afterDollar..<nameEnd])
            out.append(env[name] ?? "")
            i = nameEnd
            continue
        }
        // Lone `$` or `$1`-style — leave as-is (Compose leaves unknown forms alone).
        out.append("$")
        i = afterDollar
    }
    return out
}

private func resolveComposeInterpolation(inner: String, env: [String: String]) throws -> String {
    // VAR | VAR:-default | VAR-default | VAR:?err | VAR?err
    // Longer operators first so `:-` / `:?` win over `-` / `?`.
    func splitName(_ s: String, separators: [String]) -> (name: String, op: String, rest: String)? {
        for sep in separators {
            if let r = s.range(of: sep) {
                return (String(s[..<r.lowerBound]), sep, String(s[r.upperBound...]))
            }
        }
        return nil
    }

    // Longer operators before shorter ones so defaults may contain `?` / `-`
    // (e.g. `${DB_URL:-postgres://h/db?sslmode=disable}`).
    if let parts = splitName(inner, separators: [":?", ":-", "?", "-"]) {
        guard isComposeEnvName(parts.name) else {
            throw ComposeError.invalid("compose interpolation: invalid name \"\(parts.name)\"")
        }
        switch parts.op {
        case ":?":
            // Fail when unset or empty.
            if let value = env[parts.name], !value.isEmpty {
                return value
            }
            let message = parts.rest.isEmpty ? "required variable \(parts.name) is missing or empty" : parts.rest
            throw ComposeError.invalid("compose interpolation: \(message)")
        case "?":
            // Fail only when unset; empty string is kept.
            guard let value = env[parts.name] else {
                let message = parts.rest.isEmpty ? "required variable \(parts.name) is missing" : parts.rest
                throw ComposeError.invalid("compose interpolation: \(message)")
            }
            return value
        case ":-":
            if let value = env[parts.name], !value.isEmpty { return value }
            return parts.rest
        case "-":
            // `${VAR-default}`: default only when unset (empty string is kept).
            if let value = env[parts.name] { return value }
            return parts.rest
        default:
            break
        }
    }
    guard isComposeEnvName(inner) else {
        throw ComposeError.invalid("compose interpolation: invalid name \"\(inner)\"")
    }
    return env[inner] ?? ""
}

private func isComposeEnvName(_ name: String) -> Bool {
    guard let first = name.first else { return false }
    guard first.isLetter || first == "_" else { return false }
    return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
}

private func stringList(_ raw: Any?) -> [String] {
    if let s = raw as? String { return [s] }
    if let list = raw as? [String] { return list }
    if let list = raw as? [Any] {
        return list.compactMap { stringifyScalar($0) }
    }
    return []
}

/// R2: Compose `devices:` → `container run --device` specs (unrestricted; opt-out allowlist).
private func parseComposeDevices(_ raw: Any?, service: String) throws -> [String] {
    guard let raw else { return [] }
    let specs = try stringOrList(raw, field: "devices", service: service)
    let allowlistOnly = ProcessInfo.processInfo.environment["CONTAINER_DEVICE_ALLOWLIST_ONLY"] == "1"
    var allowed: Set<String> = ["/dev/null", "/dev/zero", "/dev/urandom", "/dev/tty"]
    if let extra = ProcessInfo.processInfo.environment["CONTAINER_DEVICE_ALLOWLIST"] {
        for part in extra.split(separator: ",") {
            let path = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty { allowed.insert(path) }
        }
    }
    var out: [String] = []
    out.reserveCapacity(specs.count)
    for spec in specs {
        let host = String(spec.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first ?? Substring(spec))
        guard host.hasPrefix("/") else {
            throw ComposeError.invalid("service \(service): device host path must be absolute (\(spec))")
        }
        if allowlistOnly, !allowed.contains(host) {
            let sorted = allowed.sorted().joined(separator: ", ")
            throw ComposeError.invalid(
                "service \(service): host device '\(host)' is not on the allowlist (allowed: \(sorted); "
                    + "extend with CONTAINER_DEVICE_ALLOWLIST or unset CONTAINER_DEVICE_ALLOWLIST_ONLY)"
            )
        }
        out.append(spec)
    }
    return out
}

private func stringOrList(_ raw: Any, field: String, service: String) throws -> [String] {
    if let s = raw as? String { return [s] }
    if let list = raw as? [String] { return list }
    if let list = raw as? [Any] {
        return try list.enumerated().map { idx, el in
            guard let s = stringifyScalar(el) else {
                throw ComposeError.invalid("service \(service): \(field)[\(idx)] must be a string")
            }
            return s
        }
    }
    throw ComposeError.invalid("service \(service): \(field) must be a string or list")
}

private func stringifyScalar(_ raw: Any?) -> String? {
    guard let raw else { return nil }
    if raw is NSNull { return "" }
    if let s = raw as? String { return s }
    if let n = raw as? Int { return String(n) }
    if let n = raw as? Double { return String(n) }
    if let b = raw as? Bool { return b ? "true" : "false" }
    return nil
}

private func optionalUInt64(_ raw: Any?, field: String, service: String) throws -> UInt64? {
    guard let raw else { return nil }
    if let n = raw as? UInt64 { return n }
    if let n = raw as? Int {
        guard n >= 0 else {
            throw ComposeError.invalid("service \(service): healthcheck.\(field) must be >= 0")
        }
        return UInt64(n)
    }
    if let s = raw as? String {
        guard let n = UInt64(s) else {
            throw ComposeError.invalid("service \(service): healthcheck.\(field) must be an integer")
        }
        return n
    }
    throw ComposeError.invalid("service \(service): healthcheck.\(field) must be an integer")
}

private func optionalDurationSeconds(_ raw: Any?, field: String, service: String) throws -> UInt64? {
    guard let raw else { return nil }
    if let n = raw as? Int, n >= 0 { return UInt64(n) }
    if let n = raw as? UInt64 { return n }
    if let s = raw as? String {
        return try ComposePlanner.parseDurationSeconds(s, field: field, service: service)
    }
    throw ComposeError.invalid("service \(service): healthcheck.\(field) must be a duration string or integer seconds")
}

extension ComposePlanner {
    /// Parse Compose-style durations (`5s`, `1.5s`, `1m`, `1m30s`, `500ms`) or bare integer seconds.
    /// Sub-second units (`ms`, `us`) and fractional seconds round up to at least 1s when
    /// non-zero so stop/health timeouts never become zero unintentionally.
    static func parseDurationSeconds(_ raw: String, field: String, service: String) throws -> UInt64 {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let n = UInt64(trimmed) { return n }
        var total: UInt64 = 0
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            var numberEnd = index
            var sawDot = false
            while numberEnd < trimmed.endIndex {
                let ch = trimmed[numberEnd]
                if ch.isNumber {
                    numberEnd = trimmed.index(after: numberEnd)
                } else if ch == ".", !sawDot {
                    sawDot = true
                    numberEnd = trimmed.index(after: numberEnd)
                } else {
                    break
                }
            }
            let number = String(trimmed[index..<numberEnd])
            guard let value = Double(number), !number.isEmpty, number != "." else {
                throw ComposeError.invalid("service \(service): invalid healthcheck.\(field) duration \"\(raw)\"")
            }
            index = numberEnd
            guard index < trimmed.endIndex else {
                throw ComposeError.invalid("service \(service): invalid healthcheck.\(field) duration \"\(raw)\"")
            }
            let unitSeconds: Double
            if trimmed[index...].hasPrefix("ms") {
                index = trimmed.index(index, offsetBy: 2)
                let seconds: UInt64 = value == 0 ? 0 : max(1, UInt64((value / 1000.0).rounded(.up)))
                let (sum, addOverflow) = total.addingReportingOverflow(seconds)
                if addOverflow {
                    throw ComposeError.invalid("service \(service): invalid healthcheck.\(field) duration \"\(raw)\"")
                }
                total = sum
                continue
            }
            if trimmed[index...].hasPrefix("us") {
                index = trimmed.index(index, offsetBy: 2)
                let seconds: UInt64 = value == 0 ? 0 : max(1, UInt64((value / 1_000_000.0).rounded(.up)))
                let (sum, addOverflow) = total.addingReportingOverflow(seconds)
                if addOverflow {
                    throw ComposeError.invalid("service \(service): invalid healthcheck.\(field) duration \"\(raw)\"")
                }
                total = sum
                continue
            }
            switch trimmed[index] {
            case "s": unitSeconds = 1
            case "m": unitSeconds = 60
            case "h": unitSeconds = 3600
            default:
                throw ComposeError.invalid("service \(service): invalid healthcheck.\(field) duration \"\(raw)\"")
            }
            index = trimmed.index(after: index)
            let scaled = value * unitSeconds
            guard scaled.isFinite, scaled >= 0, scaled <= Double(UInt64.max) else {
                throw ComposeError.invalid("service \(service): invalid healthcheck.\(field) duration \"\(raw)\"")
            }
            let seconds: UInt64 = scaled == 0 ? 0 : max(1, UInt64(scaled.rounded(.up)))
            let (sum, addOverflow) = total.addingReportingOverflow(seconds)
            if addOverflow {
                throw ComposeError.invalid("service \(service): invalid healthcheck.\(field) duration \"\(raw)\"")
            }
            total = sum
        }
        return total
    }
}

// MARK: - Runtime helpers

func waitUntilHealthy(_ containerId: String, timeoutSeconds: UInt64 = 300) async throws {
    let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
    while Date() < deadline {
        try Task.checkCancellation()
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

func waitUntilExitedZero(_ containerId: String, timeoutSeconds: UInt64 = 300) async throws {
    let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
    while Date() < deadline {
        try Task.checkCancellation()
        let json = try runContainer(["inspect", containerId])
        if let code = exitCode(fromInspectJSON: json) {
            if code == 0 { return }
            throw ComposeError.commandFailed("dependency \(containerId) exited with code \(code)")
        }
        try await Task.sleep(for: .seconds(1))
    }
    throw ComposeError.commandFailed("timed out waiting for \(containerId) to complete")
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

func exitCode(fromInspectJSON json: String) -> Int32? {
    guard let data = json.data(using: .utf8),
        let root = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
        let first = root.first
    else {
        return nil
    }
    if let status = first["status"] as? String, status.lowercased().contains("exited"),
        let code = first["exitCode"] as? Int
    {
        return Int32(code)
    }
    if let statusObj = first["status"] as? [String: Any] {
        if let state = statusObj["state"] as? String, state.lowercased().contains("stop") || state.lowercased() == "exited",
            let code = statusObj["exitCode"] as? Int
        {
            return Int32(code)
        }
    }
    return nil
}

struct InspectRow {
    var name: String
    var image: String
    var status: String
}

func inspectRow(_ id: String) throws -> InspectRow {
    let json = try runContainer(["inspect", id])
    guard let data = json.data(using: .utf8),
        let root = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
        let first = root.first
    else {
        return InspectRow(name: id, image: "?", status: "?")
    }
    let cfg = first["configuration"] as? [String: Any]
    let name = (cfg?["id"] as? String) ?? id
    let image =
        (cfg?["image"] as? [String: Any])?["reference"] as? String
        ?? cfg?["image"] as? String
        ?? "?"
    let status =
        (first["status"] as? String)
        ?? (first["status"] as? [String: Any])?["state"] as? String
        ?? "?"
    return InspectRow(name: name, image: image, status: status)
}

func extractLabels(_ row: [String: Any]) -> [String: String] {
    if let cfg = row["configuration"] as? [String: Any] {
        if let labels = cfg["labels"] as? [String: String] {
            return labels
        }
        if let labels = cfg["labels"] as? [String: Any] {
            var out: [String: String] = [:]
            for (k, v) in labels {
                out[k] = stringifyScalar(v) ?? ""
            }
            return out
        }
    }
    return [:]
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

/// Split an image reference into repository and tag without treating a registry
/// port (`localhost:5000/app:1.0`) as the tag. Digests keep `@sha256:…` as the tag.
func splitImageRepositoryTag(_ image: String) -> (repository: String, tag: String) {
    if let at = image.lastIndex(of: "@") {
        return (String(image[..<at]), String(image[at...]))
    }
    let slash = image.lastIndex(of: "/")
    let searchFrom = slash.map { image.index(after: $0) } ?? image.startIndex
    if let colon = image[searchFrom...].lastIndex(of: ":") {
        return (String(image[..<colon]), String(image[image.index(after: colon)...]))
    }
    return (image, "latest")
}

/// Run `container` with inherited stdio (logs / exec / interactive run).
func runContainerStreaming(_ args: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    let exe = ContainerCLI.current
    process.arguments = [exe] + args
    process.standardInput = FileHandle.standardInput
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw ComposeError.commandFailed("container \(args.joined(separator: " ")) failed with exit \(process.terminationStatus)")
    }
}

@discardableResult
func runContainer(_ args: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    let exe = ContainerCLI.current
    process.arguments = [exe] + args
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    // If run() throws before the drain threads start, close both ends so FDs
    // cannot accumulate across repeated compose failures.
    var draining = false
    defer {
        if !draining {
            try? out.fileHandleForWriting.close()
            try? out.fileHandleForReading.close()
            try? err.fileHandleForWriting.close()
            try? err.fileHandleForReading.close()
        }
    }
    try process.run()
    draining = true
    final class PipeBuffer: @unchecked Sendable {
        var data = Data()
    }
    let stdoutBuf = PipeBuffer()
    let stderrBuf = PipeBuffer()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
        stdoutBuf.data = out.fileHandleForReading.readDataToEndOfFile()
        group.leave()
    }
    group.enter()
    DispatchQueue.global().async {
        stderrBuf.data = err.fileHandleForReading.readDataToEndOfFile()
        group.leave()
    }
    process.waitUntilExit()
    group.wait()
    let stdout = String(data: stdoutBuf.data, encoding: .utf8) ?? ""
    let stderr = String(data: stderrBuf.data, encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
        throw ComposeError.commandFailed("container \(args.joined(separator: " ")) failed: \(stderr)\(stdout)")
    }
    return stdout
}
