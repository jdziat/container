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

import CVersion
import ContainerAPIClient
import ContainerPersistence
import ContainerPlugin
import ContainerResource
import ContainerRuntimeClient
import ContainerXPC
import Containerization
import ContainerizationEXT4
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import ContainerizationOS
import Foundation
import Logging
import SystemPackage

public actor ContainersService {
    struct ContainerState {
        var snapshot: ContainerSnapshot
        var client: RuntimeClient? = nil

        func getClient() throws -> RuntimeClient {
            guard let client else {
                var message = "no runtime client exists"
                if snapshot.status == .stopped {
                    message += ": container is stopped"
                }
                throw ContainerizationError(.invalidState, message: message)
            }
            return client
        }
    }

    private static let machServicePrefix = "com.apple.container"
    private static let launchdDomainString: String = {
        do {
            return try ServiceManager.getDomainString()
        } catch {
            // Launchd domain is required for plugin mach services; fail loud at process start.
            fatalError("ContainersService: failed to resolve launchd domain: \(error)")
        }
    }()

    private let log: Logger
    private let debugHelpers: Bool
    private let containerRoot: URL
    private let pluginLoader: PluginLoader
    private let runtimePlugins: [Plugin]
    private let exitMonitor: ExitMonitor
    private let containerSystemConfig: ContainerSystemConfig

    private let lock: AsyncLock
    private var containers: [String: ContainerState]
    /// In-flight intentional stops. Checked by the exit handler so a concurrent crash
    /// during `stop` does not schedule a restart before the on-disk marker is written.
    private var intentionalStops: Set<String> = []
    /// Continuations resumed when an in-flight stop finishes (or is abandoned), so
    /// concurrent `stop` callers suspend without a polling sleep loop. Tokens let a
    /// timed-out waiter drop only itself without waking siblings still waiting.
    private var concurrentStopWaiters: [String: [UUID: CheckedContinuation<Void, Never>]] = [:]
    /// Ensures boot-time restart starts run at most once after networks are wired.
    private var didScheduleBootStarts = false
    /// Per-container guest healthcheck probe loops (cancelled on stop/exit).
    private var healthMonitors: [String: Task<Void, Never>] = [:]
    /// Pending crash-restart backoff tasks (cancelled on stop/delete).
    private var restartTasks: [String: Task<Void, Never>] = [:]
    /// In-flight `/etc/hosts` peer refresh tasks keyed by target container id.
    private var hostsRefreshTasks: [String: Task<Void, Never>] = [:]
    /// Generation counters so a finished refresh cannot clear a newer task's map entry.
    private var hostsRefreshGenerations: [String: UInt64] = [:]
    /// Peer refreshes scheduled after an AsyncLock is released (queue so concurrent
    /// start/exit handoffs cannot overwrite each other).
    private var pendingPeerHostsRefresh: [(id: String, networks: Set<String>, retiredIPs: Set<String>)] = []
    /// Lifecycle event fan-out for `container events`.
    private let eventBus = ContainerEventBus()

    // FIXME: Find a better mechanism for services running on the APIServer to work with each other
    private weak var networksService: NetworksService?

    /// Wait for lifecycle events with id greater than `since`.
    public func events(since: UInt64) async -> [ContainerEvent] {
        // Shorter than every client long-poll timeout so the server always answers first.
        await eventBus.next(since: since, timeout: .seconds(20))
    }

    private func emitEvent(status: String, action: String, id: String, attributes: [String: String] = [:]) async {
        var attrs = attributes
        attrs["name"] = attrs["name"] ?? id
        _ = await eventBus.publish(status: status, action: action, actorID: id, attributes: attrs)
    }

    public init(
        appRoot: URL,
        pluginLoader: PluginLoader,
        containerSystemConfig: ContainerSystemConfig,
        log: Logger,
        debugHelpers: Bool = false
    ) async throws {
        let containerRoot = appRoot.appendingPathComponent("containers")
        try PathUtils.createDirectoryExcludingFromBackup(containerRoot)
        self.exitMonitor = ExitMonitor(log: log)
        self.lock = AsyncLock(log: log)
        self.containerRoot = containerRoot
        self.pluginLoader = pluginLoader
        self.containerSystemConfig = containerSystemConfig
        self.log = log
        self.debugHelpers = debugHelpers
        self.runtimePlugins = pluginLoader.findPlugins().filter { $0.hasType(.runtime) }
        self.containers = try await Self.loadAtBoot(root: containerRoot, loader: pluginLoader, log: log)
    }

    public func setNetworksService(_ service: NetworksService) async {
        self.networksService = service
        // Defer boot starts so network setup finishes, and re-validate under the
        // normal bootstrap/start locking path for each candidate. Only schedule once.
        guard !self.didScheduleBootStarts else { return }
        self.didScheduleBootStarts = true
        Task { [weak self] in
            await self?.startContainersForRestartPolicy()
        }
    }

    /// Start containers whose restart policy requires them after API server boot.
    ///
    /// Candidate selection runs on the actor (serialized with other mutations). Each
    /// bootstrap/start re-checks status so a concurrent client start or delete wins cleanly.
    private func startContainersForRestartPolicy() async {
        let candidates: [(id: String, policy: RestartPolicy)] = self.containers.compactMap { id, state in
            let policy = state.snapshot.configuration.restartPolicy
            let path = self.containerRoot.appendingPathComponent(id)
            let manuallyStopped = Self.isManuallyStopped(bundlePath: path)
            guard policy.shouldStartOnBoot(manuallyStopped: manuallyStopped) else {
                return nil
            }
            return (id, policy)
        }
        for candidate in candidates {
            // Re-check under current state: a concurrent stop/delete may have won.
            // `loadAtBoot` restores containers as `.stopped`; only start those that are
            // still stopped (skip `.running` / `.stopping` / `.unknown`).
            let path = self.containerRoot.appendingPathComponent(candidate.id)
            guard self.containers[candidate.id] != nil else { continue }
            guard !self.intentionalStops.contains(candidate.id) else { continue }
            guard !Self.isManuallyStopped(bundlePath: path) else { continue }
            guard self.containers[candidate.id]?.snapshot.status == .stopped else { continue }

            self.log.info(
                "starting container for restart policy on boot",
                metadata: [
                    "id": "\(candidate.id)",
                    "policy": "\(candidate.policy.rawValue)",
                ])
            do {
                // Bootstrap and start only while still `.stopped`. A client may have
                // started the container after loadAtBoot; skip without treating that as failure.
                guard self.containers[candidate.id]?.snapshot.status == .stopped else { continue }
                try await self.bootstrap(id: candidate.id, stdio: [nil, nil, nil], dynamicEnv: [:])
                guard self.containers[candidate.id] != nil else { continue }
                // Leave a concurrent client start alone (status left `.stopped` only while
                // we still own the sandbox). Abort if a stop won (in-memory or on-disk).
                guard self.containers[candidate.id]?.snapshot.status == .stopped else { continue }
                if self.intentionalStops.contains(candidate.id)
                    || Self.isManuallyStopped(bundlePath: path)
                {
                    try await self.abortBootstrappedRestart(id: candidate.id)
                    continue
                }
                try await self.startProcess(
                    id: candidate.id, processID: candidate.id, abortIfManuallyStopped: true)
            } catch {
                self.log.error(
                    "failed to start container for restart policy on boot",
                    metadata: [
                        "id": "\(candidate.id)",
                        "error": "\(error)",
                    ])
                // Tear down only our half-started sandbox — never a concurrent client start.
                if self.containers[candidate.id]?.snapshot.status == .stopped {
                    try? await self.abortBootstrappedRestart(id: candidate.id)
                }
            }
        }
    }

    /// Move an unbootable bundle to `<appRoot>/orphaned-containers/` instead of deleting it.
    static func quarantine(bundle: URL, root: URL, log: Logger) {
        let destinationRoot = root.deletingLastPathComponent().appendingPathComponent("orphaned-containers")
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let destination = destinationRoot.appendingPathComponent("\(bundle.lastPathComponent)-\(stamp)")
        do {
            try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: bundle, to: destination)
            log.warning(
                "container bundle has no runtime plugin; moved aside (not deleted)",
                metadata: ["from": "\(bundle.path)", "to": "\(destination.path)"])
        } catch {
            // If it cannot be moved, leave it in place: never fall back to deleting.
            log.error("could not quarantine container bundle", metadata: ["path": "\(bundle.path)", "error": "\(error)"])
        }
    }

    static func loadAtBoot(root: URL, loader: PluginLoader, log: Logger) async throws -> [String: ContainerState] {
        var directories = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        directories = directories.filter {
            $0.isDirectory
        }

        let runtimePlugins = loader.findPlugins().filter { $0.hasType(.runtime) }
        var results = [String: ContainerState]()
        for dir in directories {
            // A bundle whose runtime plugin no longer exists can never boot, so it is dropped.
            // Any other load failure (I/O, decode) may be transient and must not wipe durable
            // container state, so those bundles are left in place for a later boot to retry.
            var runtimeIsMissing = false
            do {
                let (config, options) = try Self.getContainerConfiguration(at: dir)

                guard let plugin = runtimePlugins.first(where: { $0.name == config.runtimeHandler }) else {
                    runtimeIsMissing = true
                    throw ContainerizationError(
                        .internalError,
                        message: "failed to find runtime plugin \(config.runtimeHandler)"
                    )
                }

                if options?.autoRemove ?? false {
                    log.info(
                        "reap auto-remove container",
                        metadata: [
                            "id": "\(config.id)"
                        ])

                    let label = Self.fullLaunchdServiceLabel(
                        runtimeName: config.runtimeHandler,
                        instanceId: config.id)

                    var status: Int32 = -1
                    try? ServiceManager.deregister(fullServiceLabel: label, status: &status)
                    if status != 0 {
                        log.warning(
                            "failed to deregister service",
                            metadata: [
                                "id": "\(config.id)",
                                "service": "\(label)",
                                "status": "\(status)",
                            ]
                        )
                    }

                    await RuntimeCleanupHook.run(plugin: plugin, root: dir, id: config.id, log: log)

                    let bundle = ContainerResource.Bundle(path: dir)
                    try? bundle.delete()
                    continue
                }

                let state = ContainerState(
                    snapshot: .init(
                        configuration: config,
                        status: .stopped,
                        networks: [],
                        startedDate: nil
                    ),
                )
                results[config.id] = state
            } catch {
                if runtimeIsMissing {
                    // The bundle can never boot without its runtime, so take it out of `containers/`
                    // (otherwise it is re-examined every boot). But "plugin not found" is an inference:
                    // a half-finished upgrade or a momentarily malformed plugin config looks the same.
                    // So move it aside rather than delete it; nothing is lost if the inference is wrong.
                    Self.quarantine(bundle: dir, root: root, log: log)
                }
                log.warning(
                    "failed to load container",
                    metadata: [
                        "path": "\(dir.path)",
                        "error": "\(error)",
                    ])
            }
        }
        return results
    }

    /// List containers matching the given filters.
    public func list(filters: ContainerListFilters = .all) async throws -> [ContainerSnapshot] {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)"
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)"
                ]
            )
        }

        let labelPatterns: [(key: String, regex: Regex<AnyRegexOutput>)] = try filters.labels.map { key, pattern in
            do {
                return (key: key, regex: try Regex(pattern))
            } catch {
                throw ContainerizationError(
                    .invalidArgument, message: "failed to compile regex '\(pattern)' for \(key)",
                    cause: error)
            }
        }

        return self.containers.values.compactMap { state -> ContainerSnapshot? in
            let snapshot = state.snapshot

            if !filters.ids.isEmpty {
                // `ids` accepts either the stable Id or the mutable Name (Name≠Id).
                let name = snapshot.configuration.name
                guard filters.ids.contains(snapshot.id) || filters.ids.contains(name) else {
                    return nil
                }
            }

            if let status = filters.status {
                guard snapshot.status == status else {
                    return nil
                }
            }

            for (key, regex) in labelPatterns {
                let label = snapshot.configuration.labels[key] ?? ""

                guard label.contains(regex) else {
                    return nil
                }
            }

            return snapshot
        }
    }

    /// Snapshot the container list under the lock, then run `operation` outside it
    /// so callers cannot deadlock by re-entering ContainersService.
    public func withContainerList<T: Sendable>(
        logMetadata: Logger.Metadata? = nil,
        _ operation: @Sendable @escaping ([ContainerSnapshot]) async throws -> T
    ) async throws -> T {
        let snapshots: [ContainerSnapshot] = await lock.withLock(logMetadata: logMetadata) { _ in
            await self.containers.values.map { $0.snapshot }
        }
        return try await operation(snapshots)
    }

    /// Calculate disk usage for containers
    /// - Returns: Tuple of (total count, active count, total size, reclaimable size)
    public func calculateDiskUsage() async -> (Int, Int, UInt64, UInt64) {
        // Snapshot on the actor (no AsyncLock re-entry), then size off-actor so
        // FileManager I/O does not stall other container operations.
        let root = self.containerRoot
        let items: [(path: URL, running: Bool)] = self.containers.map { id, state in
            (root.appendingPathComponent(id), state.snapshot.status == .running)
        }
        return await Task.detached(priority: .utility) {
            var totalSize: UInt64 = 0
            var reclaimableSize: UInt64 = 0
            var activeCount = 0
            for item in items {
                let containerSize = FileManager.default.allocatedSize(of: item.path)
                totalSize += containerSize
                if item.running {
                    activeCount += 1
                } else {
                    reclaimableSize += containerSize
                }
            }
            return (items.count, activeCount, totalSize, reclaimableSize)
        }.value
    }

    /// Get set of image references used by containers (for disk usage calculation)
    /// - Returns: Set of image references currently in use
    public func getActiveImageReferences() async -> Set<String> {
        await lock.withLock(logMetadata: ["acquirer": "\(#function)"]) { _ in
            var imageRefs = Set<String>()
            for (_, state) in await self.containers {
                imageRefs.insert(state.snapshot.configuration.image.reference)
            }
            return imageRefs
        }
    }

    /// Create a new container from the provided id and configuration.
    public func create(configuration: ContainerConfiguration, kernel: Kernel, options: ContainerCreateOptions, initImage: String? = nil, runtimeData: Data? = nil) async throws {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(configuration.id)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(configuration.id)",
                ]
            )
        }

        try await self.lock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(configuration.id)"]) { context in
            guard await self.containers[configuration.id] == nil else {
                throw ContainerizationError(
                    .exists,
                    message: "container already exists: \(configuration.id)"
                )
            }
            let newName = configuration.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if await self.containers.contains(where: {
                $0.value.snapshot.configuration.name.trimmingCharacters(in: .whitespacesAndNewlines) == newName
            }) {
                throw ContainerizationError(
                    .exists,
                    message: "container name already in use: \(configuration.name.isEmpty ? "(empty)" : configuration.name)"
                )
            }

            var existingNetworks = [AttachmentConfiguration]()
            for container in await self.containers.values {
                existingNetworks.append(contentsOf: container.snapshot.configuration.networks)
            }
            try AttachmentNameValidator.validate(networks: configuration.networks, existing: existingNetworks)
            try Self.validateExclusiveNamedVolumes(
                mounts: configuration.mounts,
                newID: configuration.id,
                existing: await self.containers,
                log: self.log
            )

            guard self.runtimePlugins.first(where: { $0.name == configuration.runtimeHandler }) != nil else {
                throw ContainerizationError(
                    .notFound,
                    message: "unable to locate runtime plugin \(configuration.runtimeHandler); pass --runtime to select one"
                )
            }

            try ContainerConfiguration.Resources.validate(memoryInBytes: configuration.resources.memoryInBytes)

            let path = self.containerRoot.appendingPathComponent(configuration.id)
            let systemPlatform = kernel.platform

            // Fetch init image (custom or default)
            self.log.debug(
                "ContainersService: get init block",
                metadata: [
                    "id": "\(configuration.id)"
                ]
            )
            let initFilesystem = try await self.getInitBlock(for: systemPlatform.ociPlatform(), imageRef: initImage)

            do {
                self.log.debug(
                    "create snapshot",
                    metadata: [
                        "id": "\(configuration.id)",
                        "ref": "\(configuration.image.reference)",
                    ])
                let containerImage = ClientImage(description: configuration.image)
                let imageFs = try await options.rootFsOverride == nil ? containerImage.getCreateSnapshot(platform: configuration.platform) : nil

                self.log.debug(
                    "configure runtime",
                    metadata: [
                        "id": "\(configuration.id)",
                        "kernel": "\(kernel.path)",
                        "initfs": "\(initImage ?? self.containerSystemConfig.vminit.image)",
                    ])
                let runtimeConfig = RuntimeConfiguration(
                    path: path,
                    initialFilesystem: initFilesystem,
                    kernel: kernel,
                    containerConfiguration: configuration,
                    containerRootFilesystem: imageFs,
                    options: options,
                    runtimeData: runtimeData
                )

                try runtimeConfig.writeRuntimeConfiguration()
                // Also write bundle config.json so load prefers a durable copy if
                // runtime-config.json is lost before any later persistConfiguration.
                try ContainerResource.Bundle(path: path).set(configuration: configuration)

                let snapshot = ContainerSnapshot(
                    configuration: configuration,
                    status: .stopped,
                    networks: [],
                    startedDate: nil
                )
                await self.setContainerState(configuration.id, ContainerState(snapshot: snapshot), context: context)
                await self.emitEvent(status: "create", action: "create", id: configuration.id)
            } catch {
                throw error
            }
        }
    }

    /// Bootstrap the init process of the container.
    public func bootstrap(id: String, stdio: [FileHandle?], dynamicEnv: [String: String]) async throws {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
                "env": "\(dynamicEnv)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                ]
            )
        }

        try await self.lock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(id)"]) { context in
            var state = try await self.getContainerState(id: id, context: context)

            // We've already bootstrapped this container. Ideally we should be able to
            // return some sort of error code from the sandbox svc to check here, but this
            // is also a very simple check and faster than doing an rpc to get the same result.
            if state.client != nil {
                return
            }

            let path = self.containerRoot.appendingPathComponent(id)
            let (config, _) = try Self.getContainerConfiguration(at: path)
            try AttachmentNameValidator.validateStored(id: id, networks: config.networks)
            try Self.validateExclusiveNamedVolumes(
                mounts: config.mounts,
                newID: id,
                existing: await self.containers,
                log: self.log
            )

            var networkBootstrapInfos = [NetworkBootstrapInfo]()
            for n in config.networks {
                guard let plugin = try await self.networksService?.plugin(for: n.network) else {
                    throw ContainerizationError(.internalError, message: "failed to get plugin for network \(n.network)")
                }
                networkBootstrapInfos.append(NetworkBootstrapInfo(plugin: plugin))
            }

            let peerHosts = await self.peerHostEntries(for: config, excluding: id)

            do {
                try Self.registerService(
                    plugin: self.runtimePlugins.first { $0.name == config.runtimeHandler }!,
                    loader: self.pluginLoader,
                    configuration: config,
                    path: path,
                    debug: self.debugHelpers
                )

                let runtime = state.snapshot.configuration.runtimeHandler
                let runtimeClient = try await RuntimeClient.create(
                    id: id,
                    runtime: runtime
                )
                try await runtimeClient.bootstrap(
                    stdio: stdio,
                    networkBootstrapInfos: networkBootstrapInfos,
                    dynamicEnv: dynamicEnv,
                    peerHosts: peerHosts
                )

                try await self.exitMonitor.registerProcess(
                    id: id,
                    onExit: { [weak self] exitId, code in
                        try await self?.handleContainerExit(id: exitId, code: code)
                    }
                )

                state.client = runtimeClient
                await self.setContainerState(id, state, context: context)
            } catch {
                let label = Self.fullLaunchdServiceLabel(
                    runtimeName: config.runtimeHandler,
                    instanceId: id
                )

                await self.exitMonitor.stopTracking(id: id)
                try? ServiceManager.deregister(fullServiceLabel: label)
                throw error
            }
        }
    }

    /// Create a new process in the container.
    public func createProcess(
        id: String,
        processID: String,
        config: ProcessConfiguration,
        stdio: [FileHandle?]
    ) async throws {
        let id = try self.resolveID(id)
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
                "processId": "\(processID)",
                "command": "\(config.arguments.isEmpty ? "" : config.arguments[0])",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                ]
            )
        }

        let state = try self._getContainerState(id: id)
        let client = try state.getClient()
        try await client.createProcess(
            processID,
            config: config,
            stdio: stdio
        )
    }

    /// Start a process in a container. This can either be a process created via
    /// createProcess, or the init process of the container which requires
    /// id == processID.
    public func startProcess(id: String, processID: String) async throws {
        try await self.startProcess(id: id, processID: processID, abortIfManuallyStopped: false)
    }

    /// Start a process in a container.
    ///
    /// When `abortIfManuallyStopped` is true (crash/boot restart paths), the start is
    /// skipped if an intentional-stop marker is present under the lock, closing the race
    /// where `stop` sets the marker after the caller's pre-checks.
    private func startProcess(id: String, processID: String, abortIfManuallyStopped: Bool) async throws {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
                "processId": "\(processID)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                    "processId": "\(processID)",
                ]
            )
        }

        try await self.lock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(id)", "processId": "\(processID)"]) { [self] context in
            var state = try await self.getContainerState(id: id, context: context)

            let isInit = Self.isInitProcess(id: id, processID: processID)
            if state.snapshot.status == .running && isInit {
                return
            }

            if abortIfManuallyStopped, isInit {
                let path = self.containerRoot.appendingPathComponent(id)
                if await self.isIntentionallyStopped(id: id, bundlePath: path) {
                    return
                }
            }

            let client = try state.getClient()
            try await client.startProcess(processID)

            guard isInit else {
                return
            }

            do {
                let log = self.log
                let waitFunc: ExitMonitor.WaitHandler = {
                    log.info("registering container with exit monitor")
                    let code = try await client.wait(id)
                    log.info(
                        "container finished in exit monitor",
                        metadata: [
                            "id": "\(id)",
                            "rc": "\(code)",
                        ])

                    return code
                }
                try await self.exitMonitor.track(id: id, waitingOn: waitFunc)

                let sandboxSnapshot = try await client.state()
                let path = self.containerRoot.appendingPathComponent(id)
                // Crash/boot restarts must only observe the marker — never clear it —
                // so a concurrent stop that finishes before this hop cannot lose
                // unless-stopped semantics across an API-server crash.
                // User starts clear+check atomically so stop cannot win between hops.
                let abortForStop: Bool
                if abortIfManuallyStopped {
                    abortForStop = await self.isIntentionallyStopped(id: id, bundlePath: path)
                } else {
                    abortForStop = try await self.clearManualStopUnlessIntentional(
                        id: id, bundlePath: path)
                }
                if abortForStop {
                    try? await client.stop(options: .default)
                    let label = Self.fullLaunchdServiceLabel(
                        runtimeName: state.snapshot.configuration.runtimeHandler,
                        instanceId: id
                    )
                    try? ServiceManager.deregister(fullServiceLabel: label)
                    state.snapshot.status = .stopped
                    state.snapshot.networks = []
                    state.client = nil
                    await self.setContainerState(id, state, context: context)
                    await self.exitMonitor.stopTracking(id: id)
                    return
                }
                state.snapshot.status = .running
                state.snapshot.networks = sandboxSnapshot.networks
                state.snapshot.startedDate = Date()
                // User-initiated starts reset the on-failure counter. Crash/boot restart
                // paths keep the counter so on-failure:<max> can exhaust across attempts.
                if !abortIfManuallyStopped {
                    try? Self.setRestartFailureCount(bundlePath: path, value: 0)
                }
                if state.snapshot.configuration.healthcheck != nil {
                    state.snapshot.configuration.healthStatus = .starting
                }
                await self.setContainerState(id, state, context: context)
                await self.emitEvent(status: "start", action: "start", id: id)
                await self.startHealthMonitor(id: id)
                // Peer refresh runs after this lock is released (see below).
                await self.enqueuePendingPeerHostsRefresh(
                    (id, Set(sandboxSnapshot.networks.map(\.network)), []))
            } catch {
                await self.exitMonitor.stopTracking(id: id)
                try? await client.stop(options: ContainerStopOptions.default)
                throw error
            }
        }
        for peerRefresh in self.drainPendingPeerHostsRefresh() {
            self.schedulePeerHostsRefresh(
                around: peerRefresh.id, networks: peerRefresh.networks, retiredIPs: peerRefresh.retiredIPs)
        }
    }

    /// Send a signal to the container.
    public func kill(id: String, processID: String, signal: String) async throws {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
                "processId": "\(processID)",
                "signal": "\(signal)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                    "processId": "\(processID)",
                ]
            )
        }

        let id = try self.resolveID(id)
        let state = try self._getContainerState(id: id)
        let client = try state.getClient()
        try await client.kill(processID, signal: signal)

        // SIGKILL is guaranteed to terminate the target. When directed at the
        // container's init process, let the exit monitor deliver the real exit
        // status into handleContainerExit — do not block kill on a second wait.
    }

    /// Stop all containers inside the sandbox, aborting any processes currently
    /// executing inside the container, before stopping the underlying sandbox.
    public func stop(id: String, options: ContainerStopOptions) async throws {
        let id = try self.resolveID(id)
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                ]
            )
        }

        let path = self.containerRoot.appendingPathComponent(id)

        // Stop should be idempotent across concurrent callers. If another stop is
        // already in flight, wait for that attempt to finish via continuations (no
        // polling sleep). If it succeeded the container is `.stopped` and we return;
        // if it failed we fall through and retry stop ourselves.
        if self.intentionalStops.contains(id) {
            let timeoutSeconds = Int64(max(options.timeoutInSeconds, 30)) + 120
            try await self.waitForConcurrentStop(id: id, timeoutSeconds: timeoutSeconds)
            if self.containers[id]?.snapshot.status == .stopped {
                return
            }
            // Peer stop failed while still `.running`; fall through and retry.
        }
        // Unknown id must stay `.notFound`. Already-stopped: only cancel a pending
        // crash-restart (and mark intentional stop) when a backoff Task is in flight
        // or the container previously ran. Created-never-started must not gain a
        // manual-stop marker from a no-op stop (unless-stopped would then refuse boot).
        guard let state = self.containers[id] else {
            throw ContainerizationError(.notFound, message: "container \(id) not found")
        }
        guard state.snapshot.status != .stopped else {
            // Only persist a marker when cancelling an in-flight crash-restart. A plain
            // no-op stop on an already-stopped container must not change unless-stopped boot.
            let hadRestart = self.restartTasks[id] != nil
            self.cancelRestartTask(id: id)
            if hadRestart {
                try? Self.setManuallyStopped(bundlePath: path, value: true)
            }
            return
        }

        let client: RuntimeClient
        do {
            client = try state.getClient()
        } catch {
            // No runtime client usually means already torn down; persist the marker
            // only when the container had actually started.
            if state.snapshot.startedDate != nil {
                try? Self.setManuallyStopped(bundlePath: path, value: true)
            }
            return
        }

        var resolvedOptions = options
        if resolvedOptions.signal == nil, let stopSignal = state.snapshot.configuration.stopSignal {
            resolvedOptions.signal = stopSignal
        }

        // Persist the intentional-stop marker before client.stop so an API-server
        // crash mid-stop cannot lose unless-stopped semantics on the next boot.
        // Keep intentionalStops through handleContainerExit so a concurrent exit-monitor
        // path cannot schedule a crash restart. Waiters resume after exit cleanup.
        self.intentionalStops.insert(id)
        defer {
            self.intentionalStops.remove(id)
            self.resumeConcurrentStopWaiters(id: id)
        }
        try Self.setManuallyStopped(bundlePath: path, value: true)
        do {
            try await client.stop(options: resolvedOptions)
        } catch let err as ContainerizationError {
            // `.interrupted` means the sandbox was already gone; keep the marker.
            if err.code != .interrupted {
                try? Self.setManuallyStopped(bundlePath: path, value: false)
                throw err
            }
        } catch {
            try? Self.setManuallyStopped(bundlePath: path, value: false)
            throw error
        }
        try await handleContainerExit(id: id, suppressRestart: true)
    }

    /// Suspend until the in-flight stop for `id` finishes, or `timeoutSeconds` elapses.
    private func waitForConcurrentStop(id: String, timeoutSeconds: Int64) async throws {
        let token = UUID()
        let finished: Bool = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                await self.enqueueConcurrentStopWaiter(id: id, token: token)
                return true
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                return false
            }
            let first = try await group.next() ?? false
            group.cancelAll()
            return first
        }
        if !finished {
            // Drop only this caller's waiter so sibling stop waiters stay parked.
            self.dropConcurrentStopWaiter(id: id, token: token)
            if self.containers[id]?.snapshot.status == .stopped {
                return
            }
            throw ContainerizationError(
                .timeout,
                message: "timed out waiting for concurrent stop of container \(id)"
            )
        }
    }

    private func enqueueConcurrentStopWaiter(id: String, token: UUID) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Peer may have finished between the caller's check and registration.
            if !self.intentionalStops.contains(id)
                || self.containers[id]?.snapshot.status == .stopped
            {
                continuation.resume()
                return
            }
            var waiters = self.concurrentStopWaiters[id] ?? [:]
            waiters[token] = continuation
            self.concurrentStopWaiters[id] = waiters
        }
    }

    private func dropConcurrentStopWaiter(id: String, token: UUID) {
        guard var waiters = self.concurrentStopWaiters[id] else { return }
        if let continuation = waiters.removeValue(forKey: token) {
            continuation.resume()
        }
        if waiters.isEmpty {
            self.concurrentStopWaiters.removeValue(forKey: id)
        } else {
            self.concurrentStopWaiters[id] = waiters
        }
    }

    private func resumeConcurrentStopWaiters(id: String) {
        let waiters = self.concurrentStopWaiters.removeValue(forKey: id) ?? [:]
        for (_, waiter) in waiters {
            waiter.resume()
        }
    }

    public func dial(id: String, port: UInt32) async throws -> FileHandle {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
                "port": "\(port)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                    "port": "\(port)",
                ]
            )
        }

        let id = try self.resolveID(id)
        let state = try self._getContainerState(id: id)
        let client = try state.getClient()
        return try await client.dial(port)
    }

    /// Wait waits for the container's init process or exec to exit and returns the
    /// exit status.
    public func wait(id: String, processID: String) async throws -> ExitStatus {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
                "processId": "\(processID)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                    "processId": "\(processID)",
                ]
            )
        }

        let id = try self.resolveID(id)
        let state = try self._getContainerState(id: id)
        let client = try state.getClient()
        return try await client.wait(processID)
    }

    /// Resize resizes the container's PTY if one exists.
    public func resize(id: String, processID: String, size: Terminal.Size) async throws {
        log.trace(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
                "processId": "\(processID)",
            ]
        )
        defer {
            log.trace(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                    "processId": "\(processID)",
                ]
            )
        }

        let id = try self.resolveID(id)
        let state = try self._getContainerState(id: id)
        let client = try state.getClient()
        try await client.resize(processID, size: size)
    }

    // Get the logs for the container.
    public func logs(id: String) async throws -> [FileHandle] {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                ]
            )
        }

        // Logs doesn't care if the container is running or not, just that
        // the bundle is there; a log file that doesn't exist reads as empty. We do
        // first try and get the container state so we get a nicer error message
        // (container foo not found) however.
        do {
            let id = try self.resolveID(id)
            _ = try _getContainerState(id: id)
            let path = self.containerRoot.appendingPathComponent(id)
            let bundle = ContainerResource.Bundle(path: path)
            // A missing log means there are no messages yet, not that the bundle is broken: the
            // runtime creates both at bootstrap, so a container that has never been started has
            // neither.
            return [
                try self.openLog(bundle.containerLog, of: id),
                try self.openLog(bundle.bootlog, of: id),
            ]
        } catch let err as ContainerizationError where err.code == .notFound {
            throw err
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to open container logs: \(error)"
            )
        }
    }

    /// The log at `url`, or an empty stand-in when it doesn't exist. Other failures throw.
    private func openLog(_ url: URL, of id: String) throws -> FileHandle {
        if let handle = try Self.openIfPresent(url) {
            return handle
        }
        log.debug(
            "ContainersService: log not present, returning it empty",
            metadata: ["id": "\(id)", "log": "\(url.lastPathComponent)"]
        )
        return try Self.emptyLog()
    }

    /// A stand-in for a log that doesn't exist: `/dev/null` opened for reading.
    ///
    /// Not `FileHandle.nullDevice`, which has no file descriptor (`fileDescriptor` is -1): these
    /// handles go to the client over XPC, a -1 dups back as -1, and the client's
    /// `fileHandles(key:)` then returns nil, so `container logs` would still fail.
    static func emptyLog() throws -> FileHandle {
        let fd = open("/dev/null", O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// Opens `url` for reading, or returns nil if it doesn't exist. Any other failure, such
    /// as a permissions problem, still throws.
    ///
    /// `O_NOFOLLOW`: these are fixed paths inside a container's bundle that runtimes create as
    /// regular files, so a symlink there is never legitimate, and following one would hand
    /// the caller whatever file it points at. A symlink fails with ELOOP rather than ENOENT,
    /// so it is refused, not read as an empty log.
    static func openIfPresent(_ url: URL) throws -> FileHandle? {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// Copy a file or directory from the host into the container.
    public func copyIn(id: String, source: String, destination: String, mode: UInt32, createParents: Bool = true) async throws {
        self.log.debug("\(#function)")

        let id = try self.resolveID(id)
        let state = try self._getContainerState(id: id)
        guard state.snapshot.status == .running else {
            throw ContainerizationError(.invalidState, message: "container \(id) is not running")
        }
        let client = try state.getClient()
        try await client.copyIn(source: source, destination: destination, mode: mode, createParents: createParents)
    }

    /// Copy a file or directory from the container to the host.
    public func copyOut(id: String, source: String, destination: String, createParents: Bool = true) async throws {
        self.log.debug("\(#function)")

        let id = try self.resolveID(id)
        let state = try self._getContainerState(id: id)
        guard state.snapshot.status == .running else {
            throw ContainerizationError(.invalidState, message: "container \(id) is not running")
        }
        let client = try state.getClient()
        try await client.copyOut(source: source, destination: destination, createParents: createParents)
    }

    /// Get statistics for the container.
    public func stats(id: String) async throws -> ContainerStats {
        let id = try self.resolveID(id)
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                ]
            )
        }

        let state = try self._getContainerState(id: id)
        let client = try state.getClient()
        return try await client.statistics()
    }

    /// Delete a container and its resources.
    public func delete(id: String, force: Bool) async throws {
        log.info(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
                "force": "\(force)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                ]
            )
        }

        let id = try self.resolveID(id)
        let state = try self._getContainerState(id: id)
        switch state.snapshot.status {
        case .running, .paused:
            if !force {
                throw ContainerizationError(
                    .invalidState,
                    message: "container \(id) is \(state.snapshot.status) and can not be deleted"
                )
            }
            // Route through stop() so intentionalStops / exit-monitor coordination
            // runs before cleanup (avoids treating force-delete as a crash restart).
            try await self.stop(
                id: id,
                options: ContainerStopOptions(timeoutInSeconds: 5, signal: "SIGKILL")
            )
            try await self.lock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(id)"]) { context in
                self.log.info(
                    "ContainersService: attempt cleanup",
                    metadata: [
                        "func": "\(#function)",
                        "id": "\(id)",
                    ]
                )
                try await self.cleanUp(id: id, context: context)
                self.log.info(
                    "ContainersService: successful cleanup",
                    metadata: [
                        "func": "\(#function)",
                        "id": "\(id)",
                    ]
                )
            }
        case .stopping:
            throw ContainerizationError(
                .invalidState,
                message: "container \(id) is \(state.snapshot.status) and can not be deleted"
            )
        default:
            try await self.lock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(id)"]) { context in
                try await self.cleanUp(id: id, context: context)
            }
        }
    }

    public func containerDiskUsage(id: String) async throws -> UInt64 {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                ]
            )
        }

        let id = try self.resolveID(id)
        let containerPath = self.containerRoot.appendingPathComponent(id).path

        return FileManager.default.allocatedSize(of: URL(fileURLWithPath: containerPath))
    }

    public func exportRootfs(id: String, archive: URL) async throws {
        self.log.debug("\(#function)")

        let (id, state) = try self.resolvedContainer(idOrName: id)
        let path = self.containerRoot.appendingPathComponent(id)
        let bundle = ContainerResource.Bundle(path: path)
        let rootfs = bundle.containerRootfsBlock

        switch state.snapshot.status {
        case .running:
            let client = try state.getClient()
            let snapshot = rootfs.appendingPathExtension("snapshot")
            defer { try? FileManager.default.removeItem(at: snapshot) }
            try await client.snapshotDisk(imagePath: rootfs.path, destinationPath: snapshot.path)
            try EXT4.EXT4Reader(blockDevice: FilePath(snapshot)).export(archive: FilePath(archive))
        case .paused:
            let snapshot = rootfs.appendingPathExtension("snapshot")
            defer { try? FileManager.default.removeItem(at: snapshot) }
            try FileManager.default.copyItem(at: rootfs, to: snapshot)
            try EXT4.EXT4Reader(blockDevice: FilePath(snapshot)).export(archive: FilePath(archive))
        case .stopped:
            try EXT4.EXT4Reader(blockDevice: FilePath(rootfs)).export(archive: FilePath(archive))
        default:
            throw ContainerizationError(.invalidState, message: "container must be running or stopped")
        }
    }

    public func clean(id: String) async throws {
        self.log.debug("\(#function)")

        let (id, state) = try self.resolvedContainer(idOrName: id)
        guard state.snapshot.status == .running else {
            throw ContainerizationError(.invalidState, message: "container is not running")
        }

        let client = try state.getClient()
        try await client.clean(id: id)
    }

    private func handleContainerExit(
        id: String, code: ExitStatus? = nil, suppressRestart: Bool = false,
        cancelPendingRestart: Bool = true
    ) async throws {
        // Stash refresh work on the actor so the Sendable lock closure does not mutate
        // a local `var` across isolation. Queue so concurrent start/exit handoffs keep
        // every pending refresh.
        try await self.lock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(id)"]) { [self] context in
            if let refresh = try await handleContainerExit(
                id: id, code: code, suppressRestart: suppressRestart,
                cancelPendingRestart: cancelPendingRestart, context: context)
            {
                await self.enqueuePendingPeerHostsRefresh(refresh)
            }
        }
        for peerRefresh in self.drainPendingPeerHostsRefresh() {
            self.schedulePeerHostsRefresh(
                around: peerRefresh.id, networks: peerRefresh.networks, retiredIPs: peerRefresh.retiredIPs)
        }
    }

    private func enqueuePendingPeerHostsRefresh(
        _ value: (id: String, networks: Set<String>, retiredIPs: Set<String>)
    ) {
        self.pendingPeerHostsRefresh.append(value)
    }

    private func drainPendingPeerHostsRefresh() -> [(id: String, networks: Set<String>, retiredIPs: Set<String>)] {
        let values = self.pendingPeerHostsRefresh
        self.pendingPeerHostsRefresh = []
        return values
    }

    @discardableResult
    private func handleContainerExit(
        id: String, code: ExitStatus?, suppressRestart: Bool = false,
        cancelPendingRestart: Bool = true, context: AsyncLock.Context
    ) async throws -> (
        id: String, networks: Set<String>, retiredIPs: Set<String>
    )? {
        if let code {
            self.log.info(
                "handling container exit",
                metadata: [
                    "id": "\(id)",
                    "rc": "\(code)",
                ])
        }

        var state: ContainerState
        do {
            state = try self.getContainerState(id: id, context: context)
            if state.snapshot.status == .stopped {
                return nil
            }
        } catch {
            // Was auto removed by the background thread, nothing for us to do.
            return nil
        }

        self.cancelHealthMonitor(id: id)
        // abortBootstrappedRestart runs inside the crash-restart Task; cancelling that
        // task here would turn the remainder of restartIfStillEligible into CancellationError.
        // Leave the map entry so a later user stop can still cancel the in-flight restart.
        if cancelPendingRestart {
            self.cancelRestartTask(id: id)
        }
        self.cancelHostsRefresh(id: id)
        await self.exitMonitor.stopTracking(id: id)

        // Shutdown and deregister the runtime service
        self.log.info("shutting down runtime service", metadata: ["id": "\(id)"])

        let path = self.containerRoot.appendingPathComponent(id)
        let bundle = ContainerResource.Bundle(path: path)
        let config = try bundle.configuration
        let label = Self.fullLaunchdServiceLabel(
            runtimeName: config.runtimeHandler,
            instanceId: id
        )

        // Try to shutdown the client gracefully, but if the runtime service
        // is already dead (e.g., killed externally), we should still continue
        // with state cleanup.
        if let client = state.client {
            do {
                try await client.shutdown()
            } catch {
                self.log.error(
                    "failed to shutdown runtime service",
                    metadata: [
                        "id": "\(id)",
                        "error": "\(error)",
                    ])
            }
        }

        // Deregister the service, launchd will terminate the process.
        // This may also fail if the service was already deregistered or
        // the process was killed externally.
        do {
            try ServiceManager.deregister(fullServiceLabel: label)
            self.log.info("deregistered runtime service", metadata: ["id": "\(id)"])
        } catch {
            self.log.error(
                "failed to deregister runtime service",
                metadata: [
                    "id": "\(id)",
                    "error": "\(error)",
                ])
        }

        let departedNetworks = Set(state.snapshot.networks.map(\.network))
        let departedIPs = Set(
            state.snapshot.networks.map { $0.ipv4Address.address.description }.filter { !$0.isEmpty })
        state.snapshot.status = .stopped
        state.snapshot.networks = []
        state.client = nil
        await self.setContainerState(id, state, context: context)
        await self.emitEvent(status: "die", action: "die", id: id)
        // Caller schedules peer refresh after releasing AsyncLock.

        let options = try getContainerCreationOptions(id: id)
        if options.autoRemove {
            try await self.cleanUp(id: id, context: context)
            return (id, departedNetworks, departedIPs)
        }

        // Intentional stops pass suppressRestart. Crash paths from the exit monitor
        // always supply ExitStatus; if status is missing, do not invent a failure code
        // that could schedule an on-failure restart.
        guard let status = code else {
            return (id, departedNetworks, departedIPs)
        }
        let exitCode = Int32(status.exitCode)
        // Crash-vs-stop during this API-server lifetime uses the in-memory set only.
        // The on-disk marker is for boot-time `unless-stopped` and is cleared on start;
        // reading it here would let a stale file suppress crash restarts after a later start.
        let manuallyStopped = self.intentionalStops.contains(id)
        let failureCount = Self.restartFailureCount(bundlePath: path)
        let shouldRestart =
            !suppressRestart
            && config.restartPolicy.shouldRestartOnExit(
                exitCode: exitCode,
                manuallyStopped: manuallyStopped,
                failureCount: failureCount,
                maximumRetryCount: config.restartMaxRetries
            )
        if shouldRestart {
            // Delay uses the next attempt number; the counter is persisted only when
            // restartIfStillEligible actually begins (not during a cancelled backoff).
            // User-initiated starts clear the counter; crash-restart starts do not.
            let nextCount = failureCount &+ 1
            let delayMs = RestartPolicy.backoffDelayMilliseconds(attempt: nextCount)
            self.log.info(
                "scheduling container restart",
                metadata: [
                    "id": "\(id)",
                    "policy": "\(config.restartPolicy.rawValue)",
                    "rc": "\(exitCode)",
                    "attempt": "\(nextCount)",
                    "delay_ms": "\(delayMs)",
                ])
            self.cancelRestartTask(id: id)
            self.restartTasks[id] = Task { [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(delayMs))
                    guard !Task.isCancelled, let self else { return }
                    try await self.restartIfStillEligible(id: id, attempt: nextCount)
                } catch is CancellationError {
                    return
                } catch {
                    await self?.logRestartFailure(id: id, error: error)
                }
            }
        }
        return (id, departedNetworks, departedIPs)
    }

    /// Restart after a crash only if the container still exists and was not intentionally stopped.
    ///
    /// - Parameter attempt: When set (crash-restart path), persists the on-failure attempt
    ///   count after a successful start so a failed bootstrap does not consume budget.
    ///   Cancelled backoff sleeps never reach this method, so they also do not consume.
    private func restartIfStillEligible(id: String, attempt: UInt64? = nil) async throws {
        let bundlePath = self.containerRoot.appendingPathComponent(id)
        guard self.containers[id] != nil else { return }
        guard FileManager.default.fileExists(atPath: bundlePath.path) else { return }
        guard !self.intentionalStops.contains(id) else { return }
        guard !Self.isManuallyStopped(bundlePath: bundlePath) else { return }
        // Exit handling leaves the container `.stopped` before scheduling restart.
        // Refuse other statuses so we never call bootstrap on a half-torn-down sandbox.
        guard self.containers[id]?.snapshot.status == .stopped else { return }
        try await self.bootstrap(id: id, stdio: [nil, nil, nil], dynamicEnv: [:])
        // Re-check after bootstrap. Never abort a sandbox a concurrent client start is
        // using. Tear down only when an in-memory intentional stop won.
        guard self.containers[id] != nil else { return }
        guard FileManager.default.fileExists(atPath: bundlePath.path) else { return }
        guard self.containers[id]?.snapshot.status == .stopped else { return }
        if self.intentionalStops.contains(id) || Self.isManuallyStopped(bundlePath: bundlePath) {
            try await self.abortBootstrappedRestart(id: id)
            return
        }
        do {
            try await self.startProcess(id: id, processID: id, abortIfManuallyStopped: true)
        } catch {
            // Count failed starts too so on-failure:<max> can exhaust when bootstrap
            // succeeds but startProcess throws in a crash loop.
            if let attempt {
                try? Self.setRestartFailureCount(bundlePath: bundlePath, value: attempt)
            }
            throw error
        }
        // Count the attempt once startProcess returns without throwing — including when
        // a concurrent client start already moved status to `.running`.
        if let attempt {
            try? Self.setRestartFailureCount(bundlePath: bundlePath, value: attempt)
        }
    }

    /// Tear down a sandbox that was bootstrapped for restart after a concurrent stop won.
    ///
    /// Bootstrap leaves status `.stopped` while attaching a client. Force status to
    /// `.running` under the lock so `handleContainerExit` performs full cleanup instead
    /// of returning early, then run the normal exit path.
    private func abortBootstrappedRestart(id: String) async throws {
        let hasClient = await self.lock.withLock(
            logMetadata: ["acquirer": "\(#function)", "id": "\(id)"]
        ) { context -> Bool in
            var state: ContainerState
            do {
                state = try await self.getContainerState(id: id, context: context)
            } catch {
                return false
            }
            guard state.client != nil else { return false }
            // Pretend we were running so handleContainerExit does not early-return.
            state.snapshot.status = .running
            await self.setContainerState(id, state, context: context)
            return true
        }
        guard hasClient else { return }
        try await handleContainerExit(id: id, suppressRestart: true, cancelPendingRestart: false)
    }

    private func logRestartFailure(id: String, error: Error) async {
        self.log.error(
            "failed to restart container",
            metadata: [
                "id": "\(id)",
                "error": "\(error)",
            ])
    }

    // MARK: - Healthcheck probe loop

    private func startHealthMonitor(id: String) {
        self.cancelHealthMonitor(id: id)
        guard let healthcheck = self.containers[id]?.snapshot.configuration.healthcheck,
            !healthcheck.isDisabled
        else {
            return
        }
        let startedAt = self.containers[id]?.snapshot.startedDate ?? Date()
        self.healthMonitors[id] = Task { [weak self] in
            await self?.runHealthMonitor(id: id, healthcheck: healthcheck, startedAt: startedAt)
        }
    }

    private func cancelHealthMonitor(id: String) {
        self.healthMonitors.removeValue(forKey: id)?.cancel()
    }

    private func cancelRestartTask(id: String) {
        self.restartTasks.removeValue(forKey: id)?.cancel()
    }

    private func runHealthMonitor(id: String, healthcheck: ContainerHealthcheck, startedAt: Date) async {
        let interval = max(healthcheck.intervalSeconds, 1)
        let timeout = max(healthcheck.timeoutSeconds, 1)
        let retries = max(healthcheck.retries, 1)
        var consecutiveFailures: UInt64 = 0

        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(interval))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard self.containers[id]?.snapshot.status == .running else { return }

            let success = await self.runHealthProbe(id: id, healthcheck: healthcheck, timeoutSeconds: timeout)
            let inStartPeriod =
                Date().timeIntervalSince(startedAt) < TimeInterval(healthcheck.startPeriodSeconds)

            if success {
                consecutiveFailures = 0
                await self.updateHealthStatus(id: id, status: .healthy)
            } else if inStartPeriod {
                await self.updateHealthStatus(id: id, status: .starting)
            } else {
                consecutiveFailures &+= 1
                if consecutiveFailures >= retries {
                    await self.updateHealthStatus(id: id, status: .unhealthy)
                } else if self.containers[id]?.snapshot.configuration.healthStatus != .healthy {
                    await self.updateHealthStatus(id: id, status: .starting)
                }
            }
        }
    }

    private func runHealthProbe(id: String, healthcheck: ContainerHealthcheck, timeoutSeconds: UInt64) async -> Bool {
        guard let state = self.containers[id], state.snapshot.status == .running else {
            return false
        }
        let client: RuntimeClient
        do {
            client = try state.getClient()
        } catch {
            return false
        }
        let command: (executable: String, arguments: [String])
        do {
            command = try healthcheck.resolvedCommand()
        } catch {
            self.log.error(
                "healthcheck probe misconfigured",
                metadata: ["id": "\(id)", "error": "\(error)"])
            return false
        }

        var config = state.snapshot.configuration.initProcess
        config.executable = command.executable
        config.arguments = command.arguments
        config.terminal = false

        let processID = "health-\(UUID().uuidString.lowercased())"
        do {
            try await client.createProcess(processID, config: config, stdio: [nil, nil, nil])
            try await client.startProcess(processID)
            // Race wait vs timeout with unstructured tasks so a cancellation-deaf XPC
            // wait cannot hang the health monitor after SIGKILL (task groups always
            // await remaining children when leaving scope).
            let exitCode: Int32? = try await withCheckedThrowingContinuation { continuation in
                final class Race: @unchecked Sendable {
                    var waitTask: Task<Void, Never>?
                    var timeoutTask: Task<Void, Never>?
                    private var resumed = false
                    private let lock = NSLock()
                    func finish(_ body: () -> Void) {
                        lock.lock()
                        defer { lock.unlock() }
                        guard !resumed else { return }
                        resumed = true
                        waitTask?.cancel()
                        timeoutTask?.cancel()
                        body()
                    }
                }
                let race = Race()
                race.waitTask = Task {
                    do {
                        let status = try await client.wait(processID)
                        race.finish { continuation.resume(returning: status.exitCode) }
                    } catch is CancellationError {
                        return
                    } catch {
                        race.finish { continuation.resume(throwing: error) }
                    }
                }
                race.timeoutTask = Task {
                    do {
                        try await Task.sleep(for: .seconds(timeoutSeconds))
                        guard !Task.isCancelled else { return }
                        try? await client.kill(processID, signal: "SIGKILL")
                        race.finish { continuation.resume(returning: nil) }
                    } catch is CancellationError {
                        return
                    } catch {
                        race.finish { continuation.resume(throwing: error) }
                    }
                }
            }
            return exitCode == 0
        } catch {
            self.log.debug(
                "healthcheck probe failed",
                metadata: ["id": "\(id)", "error": "\(error)"])
            try? await client.kill(processID, signal: "SIGKILL")
            return false
        }
    }

    private func updateHealthStatus(id: String, status: ContainerHealthStatus) async {
        guard var state = self.containers[id] else { return }
        guard state.snapshot.configuration.healthStatus != status else { return }
        state.snapshot.configuration.healthStatus = status
        self.containers[id] = state
        // Keep healthStatus in the in-memory snapshot only. Persisting probe results into
        // the durable config would restore a stale healthy/unhealthy value after API restart
        // before any probe has run again.
        self.log.info(
            "container health status updated",
            metadata: ["id": "\(id)", "status": "\(status.rawValue)"])
    }

    private static let manualStopFilename = "manual-stop.json"
    private static let restartFailureCountFilename = "restart-failure-count.json"

    private static func setManuallyStopped(bundlePath: URL, value: Bool) throws {
        let bundle = ContainerResource.Bundle(path: bundlePath)
        try bundle.write(filename: Self.manualStopFilename, value: value)
    }

    private static func isManuallyStopped(bundlePath: URL) -> Bool {
        let bundle = ContainerResource.Bundle(path: bundlePath)
        let path = bundle.filePath(for: Self.manualStopFilename)
        guard FileManager.default.fileExists(atPath: path.path) else {
            return false
        }
        do {
            return try bundle.load(filename: Self.manualStopFilename) as Bool
        } catch {
            // Corrupt/unreadable marker: fail closed so unless-stopped stays stopped.
            // Rewrite a clean `true` so a later successful start can clear it normally.
            try? Self.setManuallyStopped(bundlePath: bundlePath, value: true)
            return true
        }
    }

    private static func setRestartFailureCount(bundlePath: URL, value: UInt64) throws {
        let bundle = ContainerResource.Bundle(path: bundlePath)
        try bundle.write(filename: Self.restartFailureCountFilename, value: value)
    }

    private static func restartFailureCount(bundlePath: URL) -> UInt64 {
        let bundle = ContainerResource.Bundle(path: bundlePath)
        let path = bundle.filePath(for: Self.restartFailureCountFilename)
        guard FileManager.default.fileExists(atPath: path.path) else {
            return 0
        }
        do {
            return try bundle.load(filename: Self.restartFailureCountFilename) as UInt64
        } catch {
            // Corrupt counter: reset so on-failure caps are not permanently exhausted.
            try? Self.setRestartFailureCount(bundlePath: bundlePath, value: 0)
            return 0
        }
    }

    private func isIntentionallyStopped(id: String, bundlePath: URL) -> Bool {
        self.intentionalStops.contains(id) || Self.isManuallyStopped(bundlePath: bundlePath)
    }

    /// Returns `true` when a concurrent intentional stop is in flight (abort start).
    /// Otherwise clears the durable manual-stop marker left by a prior `stop`.
    ///
    /// Only the in-memory `intentionalStops` set gates the abort — the on-disk marker is
    /// what this function clears so a normal `start` after `stop` can succeed.
    private func clearManualStopUnlessIntentional(id: String, bundlePath: URL) throws -> Bool {
        if self.intentionalStops.contains(id) {
            return true
        }
        try Self.setManuallyStopped(bundlePath: bundlePath, value: false)
        return false
    }

    /// Collect running peers that share a network with `config`, for guest `/etc/hosts` injection.
    ///
    /// Only `.running` peers are included so `/etc/hosts` does not point at IPs from
    /// containers that are stopping or unknown.
    private func peerHostEntries(for config: ContainerConfiguration, excluding id: String) -> [PeerHostEntry] {
        let networkIds = Set(config.networks.map(\.network))
        guard !networkIds.isEmpty else { return [] }

        var peers: [PeerHostEntry] = []
        for (otherId, other) in self.containers where otherId != id {
            guard other.snapshot.status == .running else { continue }
            for attachment in other.snapshot.networks where networkIds.contains(attachment.network) {
                let aliases =
                    other.snapshot.configuration.networks
                    .first(where: { $0.network == attachment.network })?
                    .options.aliases ?? []
                let hostnames = PeerHostEntry.hostnames(fromHostname: attachment.hostname, aliases: aliases)
                guard !hostnames.isEmpty else { continue }
                let ip = attachment.ipv4Address.address.description
                guard !ip.isEmpty else { continue }
                peers.append(PeerHostEntry(ipAddress: ip, hostnames: hostnames))
            }
        }
        // Stable order so duplicate hostnames resolve deterministically (first wins).
        return peers.sorted { lhs, rhs in
            if lhs.ipAddress != rhs.ipAddress { return lhs.ipAddress < rhs.ipAddress }
            return lhs.hostnames.joined(separator: "\t") < rhs.hostnames.joined(separator: "\t")
        }
    }

    /// Schedule `/etc/hosts` refresh for running peers that share networks with `id`.
    ///
    /// Each target gets a tracked Task that is cancelled when that container stops, so a
    /// late-join refresh cannot write into a sandbox mid-teardown.
    ///
    /// - Parameter retiredIPs: Addresses of containers that just left; dropped from the
    ///   first unmarked merge so departed peers do not keep resolving.
    private func schedulePeerHostsRefresh(
        around id: String, networks: Set<String>? = nil, retiredIPs: Set<String> = []
    ) {
        let networkIds: Set<String>
        if let networks {
            networkIds = networks
        } else if let state = self.containers[id] {
            networkIds = Set(state.snapshot.networks.map(\.network))
        } else {
            return
        }
        guard !networkIds.isEmpty else { return }

        let targets = self.containers.compactMap { otherId, other -> String? in
            guard otherId != id, other.snapshot.status == .running else { return nil }
            let otherNetworks = Set(other.snapshot.networks.map(\.network))
            guard !networkIds.isDisjoint(with: otherNetworks) else { return nil }
            return otherId
        }
        for targetId in targets {
            self.hostsRefreshTasks[targetId]?.cancel()
            let generation = (self.hostsRefreshGenerations[targetId] ?? 0) &+ 1
            self.hostsRefreshGenerations[targetId] = generation
            self.hostsRefreshTasks[targetId] = Task { [weak self] in
                guard let self else { return }
                await self.writeHostsFile(for: targetId, generation: generation, retiredIPs: retiredIPs)
                await self.clearHostsRefreshTask(id: targetId, generation: generation)
            }
        }
    }

    private func cancelHostsRefresh(id: String) {
        self.hostsRefreshTasks[id]?.cancel()
        self.hostsRefreshTasks[id] = nil
        self.hostsRefreshGenerations[id] = (self.hostsRefreshGenerations[id] ?? 0) &+ 1
    }

    private func clearHostsRefreshTask(id: String, generation: UInt64) {
        // Only clear if we are still the current generation; a newer refresh must not be dropped.
        if self.hostsRefreshGenerations[id] == generation {
            self.hostsRefreshTasks[id] = nil
        }
    }

    private static let peersBeginMarker = "# BEGIN container-managed-peers"
    private static let peersEndMarker = "# END container-managed-peers"

    /// Rebuild the managed peer block in guest `/etc/hosts` without dropping other entries.
    ///
    /// - Parameter generation: Refresh generation for `id`. If a newer refresh was
    ///   scheduled, this write aborts before `install` so a cancelled refresh cannot
    ///   overwrite a newer peer set.
    /// - Parameter retiredIPs: Addresses to strip on the first unmarked merge (departed peers).
    private func writeHostsFile(for id: String, generation: UInt64, retiredIPs: Set<String> = []) async {
        guard self.hostsRefreshGenerations[id] == generation else { return }
        guard let state = self.containers[id], state.snapshot.status == .running else { return }
        let client: RuntimeClient
        do {
            client = try state.getClient()
        } catch {
            return
        }

        // Only peers belong in the managed block. Putting this container's own
        // addresses into managedIPs makes the first unmarked merge drop the
        // bootstrap self line, so a concurrent peer can appear before identity
        // (and break tests that expect localhost then self).
        var peerLines: [String] = []
        for peer in self.peerHostEntries(for: state.snapshot.configuration, excluding: id) {
            peerLines.append("\(peer.ipAddress)\t\(peer.hostnames.joined(separator: "\t"))")
        }
        let managedBlock =
            ([Self.peersBeginMarker] + peerLines + [Self.peersEndMarker]).joined(separator: "\n")

        let tmpOut = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-hosts-out-\(id)-\(UUID().uuidString)")
        let tmpIn = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-hosts-in-\(id)-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: tmpOut)
            try? FileManager.default.removeItem(at: tmpIn)
        }
        do {
            try await client.copyOut(source: "/etc/hosts", destination: tmpOut.path)
            guard self.hostsRefreshGenerations[id] == generation else { return }
            guard self.containers[id]?.snapshot.status == .running else { return }
            guard let existing = try? String(contentsOf: tmpOut, encoding: .utf8) else {
                self.log.warning(
                    "skipping peer hosts refresh: existing /etc/hosts is not valid UTF-8",
                    metadata: ["id": "\(id)"])
                return
            }
            let managedIPs = Set(
                peerLines.compactMap { line -> String? in
                    line.split(whereSeparator: { $0 == "\t" || $0 == " " }).first.map(String.init)
                })
            let merged = Self.mergeManagedPeersBlock(
                existing: existing, managedBlock: managedBlock, managedIPs: managedIPs,
                retiredIPs: retiredIPs)
            try merged.write(to: tmpIn, atomically: true, encoding: .utf8)
            // Stage then install as root:root 0644 so we do not leave /etc/hosts owned by
            // the copy-in user (bootstrap writes hosts as root). Avoid shell interpolation:
            // pass the staged path as an argv element to install/rm.
            let staged = "/tmp/container-hosts-refresh-\(UUID().uuidString.lowercased())"
            try await client.copyIn(source: tmpIn.path, destination: staged, mode: 0o644)
            // Last chance to drop a superseded refresh before mutating guest hosts.
            let rootUtility: (String, [String]) -> ContainerResource.ProcessConfiguration = { executable, arguments in
                var config = state.snapshot.configuration.initProcess
                config.executable = executable
                config.arguments = arguments
                config.terminal = false
                config.workingDirectory = "/"
                config.user = .id(uid: 0, gid: 0)
                return config
            }
            guard self.hostsRefreshGenerations[id] == generation,
                self.containers[id]?.snapshot.status == .running
            else {
                let cleanup = rootUtility("/bin/rm", ["-f", staged])
                let cleanupID = "hosts-cleanup-\(UUID().uuidString.lowercased())"
                try? await client.createProcess(cleanupID, config: cleanup, stdio: [nil, nil, nil])
                try? await client.startProcess(cleanupID)
                _ = try? await client.wait(cleanupID)
                return
            }
            // Write beside /etc/hosts then `mv` so the publish is atomic on the guest FS.
            let hostsNew = "/etc/hosts.container-new"
            let install = rootUtility(
                "/usr/bin/install", ["-o", "root", "-g", "root", "-m", "644", staged, hostsNew])
            let processID = "hosts-\(UUID().uuidString.lowercased())"
            let removeTemps: () async -> Void = {
                let cleanup = rootUtility("/bin/rm", ["-f", staged, hostsNew])
                let cleanupID = "hosts-rm-\(UUID().uuidString.lowercased())"
                try? await client.createProcess(cleanupID, config: cleanup, stdio: [nil, nil, nil])
                try? await client.startProcess(cleanupID)
                _ = try? await client.wait(cleanupID)
            }
            do {
                try await client.createProcess(processID, config: install, stdio: [nil, nil, nil])
            } catch {
                await removeTemps()
                throw error
            }
            // Re-check immediately before mutating /etc/hosts so a newer refresh wins.
            guard self.hostsRefreshGenerations[id] == generation,
                self.containers[id]?.snapshot.status == .running
            else {
                await removeTemps()
                return
            }
            do {
                try await client.startProcess(processID)
                let installStatus = try await client.wait(processID)
                guard installStatus.exitCode == 0 else {
                    await removeTemps()
                    throw ContainerizationError(
                        .internalError,
                        message: "install /etc/hosts staging failed with rc \(installStatus.exitCode)"
                    )
                }
                let move = rootUtility("/bin/mv", ["-f", hostsNew, "/etc/hosts"])
                let moveID = "hosts-mv-\(UUID().uuidString.lowercased())"
                try await client.createProcess(moveID, config: move, stdio: [nil, nil, nil])
                try await client.startProcess(moveID)
                let moveStatus = try await client.wait(moveID)
                await removeTemps()
                guard moveStatus.exitCode == 0 else {
                    throw ContainerizationError(
                        .internalError,
                        message: "mv /etc/hosts failed with rc \(moveStatus.exitCode)"
                    )
                }
            } catch {
                await removeTemps()
                throw error
            }
            self.log.info("refreshed peer hosts", metadata: ["id": "\(id)"])
        } catch is CancellationError {
            return
        } catch {
            self.log.warning(
                "failed to refresh peer hosts",
                metadata: ["id": "\(id)", "error": "\(error)"])
        }
    }

    /// Replace or append the managed peers block while preserving other `/etc/hosts` lines.
    static func mergeManagedPeersBlock(
        existing: String, managedBlock: String, managedIPs: Set<String> = [],
        retiredIPs: Set<String> = []
    ) -> String {
        let begin = peersBeginMarker
        let end = peersEndMarker
        if let beginRange = existing.range(of: begin),
            let endRange = existing.range(of: end, range: beginRange.upperBound..<existing.endIndex)
        {
            let before = existing[..<beginRange.lowerBound]
            let after = existing[endRange.upperBound...]
            var merged = String(before) + managedBlock
            if !after.hasPrefix("\n") { merged += "\n" }
            merged += after
            if !merged.hasSuffix("\n") { merged += "\n" }
            return merged
        }
        // No markers yet (bootstrap-written hosts): drop current managed IPs (rewritten in
        // the block) and retired IPs (departed peers), keep loopback and any other lines
        // (image/user hosts), then append the marked block.
        let dropIPs = managedIPs.union(retiredIPs)
        let preserved = existing.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("#") { return true }
                let ip =
                    trimmed.split(whereSeparator: { $0 == "\t" || $0 == " " }).first.map(String.init)
                    ?? ""
                return !dropIPs.contains(ip)
            }
        var lines = preserved.filter { !$0.isEmpty }
        if lines.isEmpty { lines = ["127.0.0.1\tlocalhost"] }
        return lines.joined(separator: "\n") + "\n" + managedBlock + "\n"
    }

    private static func fullLaunchdServiceLabel(runtimeName: String, instanceId: String) -> String {
        "\(Self.launchdDomainString)/\(Self.machServicePrefix).\(runtimeName).\(instanceId)"
    }

    private func _cleanUp(id: String) async throws {
        log.debug(
            "ContainersService: enter",
            metadata: [
                "func": "\(#function)",
                "id": "\(id)",
            ]
        )
        defer {
            log.debug(
                "ContainersService: exit",
                metadata: [
                    "func": "\(#function)",
                    "id": "\(id)",
                ]
            )
        }

        // Did the exit container handler win?
        if self.containers[id] == nil {
            return
        }

        // To be pedantic. This is only needed if something in the "launch
        // the init process" lifecycle fails before actually fork+exec'ing
        // the OCI runtime.
        self.cancelHostsRefresh(id: id)
        self.cancelHealthMonitor(id: id)
        self.cancelRestartTask(id: id)
        await self.exitMonitor.stopTracking(id: id)
        let path = self.containerRoot.appendingPathComponent(id)

        // Try to get config for service deregistration
        // Don't fail if bundle is incomplete
        var config: ContainerConfiguration?
        let bundle = ContainerResource.Bundle(path: path)
        do {
            config = try bundle.configuration
        } catch {
            self.log.warning(
                "failed to read bundle configuration during cleanup for container",
                metadata: [
                    "id": "\(id)",
                    "error": "\(error)",
                ])
        }

        // Only try to deregister service if we have a valid config
        // TODO: Change this so we don't have to reread the config
        // possibly store the container ID to service label mapping
        let plugin = config.flatMap { config in self.runtimePlugins.first { $0.name == config.runtimeHandler } }
        if let config = config {
            let label = Self.fullLaunchdServiceLabel(
                runtimeName: config.runtimeHandler,
                instanceId: id
            )
            try? ServiceManager.deregister(fullServiceLabel: label)

            if let plugin {
                await RuntimeCleanupHook.run(plugin: plugin, root: path, id: id, log: self.log)
            } else {
                self.log.warning("no runtime plugin for container; skipping cleanup hook", metadata: ["id": "\(id)", "runtime": "\(config.runtimeHandler)"])
            }
        }

        // Always try to delete the bundle directory, even if it's incomplete
        do {
            try bundle.delete()
        } catch {
            self.log.warning(
                "failed to delete bundle for container",
                metadata: [
                    "id": "\(id)",
                    "error": "\(error)",
                ])
        }

        self.containers.removeValue(forKey: id)
        await self.emitEvent(status: "destroy", action: "destroy", id: id)
    }

    private func cleanUp(id: String, context: AsyncLock.Context) async throws {
        try await self._cleanUp(id: id)
    }

    private func getContainerCreationOptions(id: String) throws -> ContainerCreateOptions {
        let path = self.containerRoot.appendingPathComponent(id)
        let bundle = ContainerResource.Bundle(path: path)
        let options: ContainerCreateOptions = try bundle.load(filename: "options.json")
        return options
    }

    private func getInitBlock(for platform: Platform, imageRef: String? = nil) async throws -> Filesystem {
        let ref = imageRef ?? containerSystemConfig.vminit.image
        let initImage = try await ClientImage.fetch(reference: ref, platform: platform, containerSystemConfig: containerSystemConfig)
        var fs = try await initImage.getCreateSnapshot(platform: platform)
        fs.options = ["ro"]
        return fs
    }

    private static func registerService(
        plugin: Plugin,
        loader: PluginLoader,
        configuration: ContainerConfiguration,
        path: URL,
        debug: Bool
    ) throws {
        let args = [
            "start",
            "--root", path.path,
            "--uuid", configuration.id,
            debug ? "--debug" : nil,
        ].compactMap { $0 }
        try loader.registerWithLaunchd(
            plugin: plugin,
            pluginStateRoot: path,
            args: args,
            instanceId: configuration.id
        )
    }

    private func setContainerState(_ id: String, _ state: ContainerState, context: AsyncLock.Context) async {
        self.containers[id] = state
    }

    private func getContainerState(id: String, context: AsyncLock.Context) throws -> ContainerState {
        try self._getContainerState(id: id)
    }

    /// Looks up by stable Id only. Call ``resolveID`` first when the caller may pass a Name.
    private func _getContainerState(id: String) throws -> ContainerState {
        guard let state = self.containers[id] else {
            throw ContainerizationError(
                .notFound,
                message: "container with ID \(id) not found"
            )
        }
        return state
    }

    /// Resolve Id-or-Name then return the canonical Id with its in-memory state.
    private func resolvedContainer(idOrName: String) throws -> (id: String, state: ContainerState) {
        let id = try self.resolveID(idOrName)
        return (id, try self._getContainerState(id: id))
    }

    /// Resolve a caller-supplied Id or Name to the stable container Id.
    public func resolveID(_ idOrName: String) throws -> String {
        let key = idOrName.trimmingCharacters(in: .whitespacesAndNewlines)
        if self.containers[key] != nil {
            return key
        }
        if let match = self.containers.first(where: {
            $0.value.snapshot.configuration.name.trimmingCharacters(in: .whitespacesAndNewlines) == key
        }) {
            return match.key
        }
        throw ContainerizationError(
            .notFound,
            message: "container with ID or name \(idOrName) not found"
        )
    }

    /// Attach a container to a network.
    ///
    /// Running containers prefer ``RuntimeClient/hotplugNetwork`` (CR or VZ spare-NIC swap).
    /// On failure, fall back to transparent stop+start. Disable with `CONTAINER_NET_HOTPLUG=0`.
    /// `restartIfRunning` is accepted for CLI compatibility but no longer required.
    public func networkConnect(
        idOrName: String,
        network: String,
        aliases: [String],
        restartIfRunning: Bool
    ) async throws {
        _ = restartIfRunning
        guard let networksService = self.networksService else {
            throw ContainerizationError(.invalidState, message: "networks service is not available")
        }
        let networks = try await networksService.list()
        guard let networkResource = networks.first(where: { $0.id == network || $0.name == network }) else {
            throw ContainerizationError(.notFound, message: "network \(network) not found")
        }
        let networkID = networkResource.id

        let pending = try await self.lock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(idOrName)"]) {
            [self] context -> (id: String, needsRestart: Bool, attachment: AttachmentConfiguration, client: RuntimeClient?) in
            let id = try await self.resolveID(idOrName)
            var state = try await self.getContainerState(id: id, context: context)
            if state.snapshot.configuration.networks.contains(where: { $0.network == networkID }) {
                throw ContainerizationError(.exists, message: "container \(id) already connected to \(network)")
            }
            let hostname = state.snapshot.configuration.name
            let attachment = AttachmentConfiguration(
                network: networkID,
                options: AttachmentOptions(hostname: hostname, aliases: aliases)
            )
            let existing = await self.containers.values
                .filter { $0.snapshot.configuration.id != id }
                .flatMap { $0.snapshot.configuration.networks }
            try AttachmentNameValidator.validate(
                networks: state.snapshot.configuration.networks + [attachment],
                existing: existing
            )
            let needsRestart = state.snapshot.status == .running
            state.snapshot.configuration.networks.append(attachment)
            try Self.persistConfiguration(state.snapshot.configuration, id: id, containerRoot: self.containerRoot)
            await self.setContainerState(id, state, context: context)
            await self.emitEvent(
                status: "connect", action: "connect", id: id,
                attributes: ["network": networkID])
            return (id, needsRestart, attachment, try? state.getClient())
        }
        if pending.needsRestart {
            if Self.preferCRNetHotplug(), let client = pending.client {
                do {
                    let pluginName = try await networksService.plugin(for: networkID)
                    try await client.hotplugNetwork(
                        attachment: pending.attachment,
                        plugin: .init(plugin: pluginName)
                    )
                    // Refresh live attachment list so inspect/status shows the new NIC.
                    if let sandbox = try? await client.state() {
                        try await self.lock.withLock(logMetadata: ["acquirer": "hotplug-refresh", "id": "\(pending.id)"]) {
                            [self] context in
                            var state = try await self.getContainerState(id: pending.id, context: context)
                            state.snapshot.networks = sandbox.networks
                            await self.setContainerState(pending.id, state, context: context)
                        }
                    }
                    self.log.info("networkConnect used live hotplug", metadata: ["id": "\(pending.id)", "network": "\(networkID)"])
                    return
                } catch {
                    self.log.warning(
                        "net hotplug failed; falling back to auto-restart",
                        metadata: ["id": "\(pending.id)", "error": "\(error)"]
                    )
                    // Strict mode: surface the live-hotplug failure instead of masking it
                    // behind stop+start (R1 diagnostics / harness).
                    if ProcessInfo.processInfo.environment["CONTAINER_NET_HOTPLUG_STRICT"] == "1" {
                        throw error
                    }
                }
            }
            try await self.stop(id: pending.id, options: .default)
            try await self.bootstrap(id: pending.id, stdio: [nil, nil, nil], dynamicEnv: [:])
            try await self.startProcess(id: pending.id, processID: pending.id)
        }
    }

    /// Whether to try live NIC hotplug before auto-restart on `network connect`.
    ///
    /// Default **on** for CR and VZ (R1). Disable with `CONTAINER_NET_HOTPLUG=0`.
    private static func preferCRNetHotplug() -> Bool {
        let env = ProcessInfo.processInfo.environment
        if env["CONTAINER_NET_HOTPLUG"] == "0" { return false }
        return true
    }

    /// Detach a container from a network.
    ///
    /// Secondary NICs prefer live ``RuntimeClient/unplugNetwork`` (R1); primary still
    /// stop+starts so the default route/ports stay coherent.
    public func networkDisconnect(
        idOrName: String,
        network: String,
        restartIfRunning: Bool,
        force: Bool
    ) async throws {
        _ = restartIfRunning
        let networkID: String
        if let networksService = self.networksService,
            let match = try await networksService.list().first(where: { $0.id == network || $0.name == network })
        {
            networkID = match.id
        } else {
            networkID = network
        }
        let pending = try await self.lock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(idOrName)"]) {
            [self] context -> (id: String, needsRestart: Bool, client: RuntimeClient?, unplugID: String?)? in
            let id = try await self.resolveID(idOrName)
            var state = try await self.getContainerState(id: id, context: context)
            let before = state.snapshot.configuration.networks.count
            let primaryNetwork = state.snapshot.configuration.networks.first?.network
            guard
                let index = state.snapshot.configuration.networks.firstIndex(where: {
                    $0.network == networkID || $0.network == network
                })
            else {
                if force { return nil }
                throw ContainerizationError(
                    .notFound, message: "container \(id) is not connected to \(network)")
            }
            // The first attachment is the primary NIC (default route + published ports).
            let removing = state.snapshot.configuration.networks[index].network
            if removing == primaryNetwork && before > 1 && !force {
                throw ContainerizationError(
                    .invalidState,
                    message: "cannot disconnect primary network \(network) while other networks remain; disconnect secondaries first or pass --force"
                )
            }
            let running = state.snapshot.status == .running
            let secondary = index > 0
            let preferUnplug = Self.preferCRNetHotplug() && secondary && running
            let needsRestart = running && !preferUnplug
            state.snapshot.configuration.networks.remove(at: index)
            if preferUnplug {
                // Drop matching live attachment from snapshot eagerly; runtime unplug refreshes.
                state.snapshot.networks.removeAll { $0.network == removing }
            }
            try Self.persistConfiguration(state.snapshot.configuration, id: id, containerRoot: self.containerRoot)
            await self.setContainerState(id, state, context: context)
            await self.emitEvent(
                status: "disconnect", action: "disconnect", id: id,
                attributes: ["network": network])
            return (id, needsRestart, try? state.getClient(), preferUnplug ? removing : nil)
        }
        guard let pending else { return }
        if let unplugID = pending.unplugID, let client = pending.client {
            do {
                try await client.unplugNetwork(networkID: unplugID)
                if let sandbox = try? await client.state() {
                    try await self.lock.withLock(logMetadata: ["acquirer": "unplug-refresh", "id": "\(pending.id)"]) {
                        [self] context in
                        var state = try await self.getContainerState(id: pending.id, context: context)
                        state.snapshot.networks = sandbox.networks
                        await self.setContainerState(pending.id, state, context: context)
                    }
                }
                self.log.info("networkDisconnect used live unplug", metadata: ["id": "\(pending.id)", "network": "\(unplugID)"])
                return
            } catch {
                self.log.warning(
                    "net unplug failed; falling back to auto-restart",
                    metadata: ["id": "\(pending.id)", "error": "\(error)"]
                )
                if ProcessInfo.processInfo.environment["CONTAINER_NET_HOTPLUG_STRICT"] == "1" {
                    throw error
                }
                try await self.stop(id: pending.id, options: .default)
                try await self.bootstrap(id: pending.id, stdio: [nil, nil, nil], dynamicEnv: [:])
                try await self.startProcess(id: pending.id, processID: pending.id)
                return
            }
        }
        if pending.needsRestart {
            try await self.stop(id: pending.id, options: .default)
            try await self.bootstrap(id: pending.id, stdio: [nil, nil, nil], dynamicEnv: [:])
            try await self.startProcess(id: pending.id, processID: pending.id)
        }
    }

    /// Apply a partial configuration update. CPU/memory changes on a running
    /// container are persisted and take effect on the next start; restart policy
    /// applies immediately.
    public func update(idOrName: String, request: ContainerUpdateRequest) async throws {
        try await self.lock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(idOrName)"]) { [self] context in
            let id = try await self.resolveID(idOrName)
            var state = try await self.getContainerState(id: id, context: context)
            if let cpus = request.cpus {
                try ContainerConfiguration.Resources.validate(cpus: Int64(cpus))
                state.snapshot.configuration.resources.cpus = cpus
            }
            if let memory = request.memoryInBytes {
                try ContainerConfiguration.Resources.validate(memoryInBytes: memory)
                state.snapshot.configuration.resources.memoryInBytes = memory
            }
            if let policy = request.restartPolicy {
                state.snapshot.configuration.restartPolicy = policy
                state.snapshot.configuration.restartMaxRetries = request.restartMaxRetries
            }
            try Self.persistConfiguration(state.snapshot.configuration, id: id, containerRoot: self.containerRoot)
            await self.setContainerState(id, state, context: context)
            await self.emitEvent(status: "update", action: "update", id: id)
        }
    }

    /// Suspend the container VM (Docker `pause`).
    public func pause(idOrName: String) async throws {
        try await self.lock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(idOrName)"]) { [self] context in
            let id = try await self.resolveID(idOrName)
            var state = try await self.getContainerState(id: id, context: context)
            switch state.snapshot.status {
            case .paused:
                return
            case .running:
                break
            default:
                throw ContainerizationError(
                    .invalidState,
                    message: "container \(id) is \(state.snapshot.status) and cannot be paused"
                )
            }
            let client = try state.getClient()
            try await client.pause()
            state.snapshot.status = .paused
            await self.setContainerState(id, state, context: context)
            await self.emitEvent(status: "pause", action: "pause", id: id)
        }
    }

    /// Resume a paused container VM (Docker `unpause`).
    public func unpause(idOrName: String) async throws {
        try await self.lock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(idOrName)"]) { [self] context in
            let id = try await self.resolveID(idOrName)
            var state = try await self.getContainerState(id: id, context: context)
            switch state.snapshot.status {
            case .running:
                return
            case .paused:
                break
            default:
                throw ContainerizationError(
                    .invalidState,
                    message: "container \(id) is \(state.snapshot.status) and cannot be unpaused"
                )
            }
            let client = try state.getClient()
            try await client.resume()
            state.snapshot.status = .running
            await self.setContainerState(id, state, context: context)
            await self.emitEvent(status: "unpause", action: "unpause", id: id)
        }
    }

    /// Filesystem changes vs the image snapshot (Docker `diff`).
    public func diff(idOrName: String) async throws -> [ContainerDiffChange] {
        // Capture a stable block + image refs under the service lock so stop/delete
        // cannot tear down the client mid-snapshotDisk.
        let prepared = try await self.lock.withLock(
            logMetadata: ["acquirer": "\(#function)", "id": "\(idOrName)"]
        ) { [self] context -> (id: String, containerBlock: URL, snapshotCleanup: URL?, image: ImageDescription, platform: Platform) in
            let id = try await self.resolveID(idOrName)
            let state = try await self.getContainerState(id: id, context: context)
            let path = self.containerRoot.appendingPathComponent(id)
            let bundle = ContainerResource.Bundle(path: path)
            let rootfs = bundle.containerRootfsBlock
            let image = state.snapshot.configuration.image
            let platform = state.snapshot.configuration.platform

            switch state.snapshot.status {
            case .running:
                let client = try state.getClient()
                let snapshot = rootfs.appendingPathExtension("diff-snapshot")
                try await client.snapshotDisk(imagePath: rootfs.path, destinationPath: snapshot.path)
                return (id, snapshot, snapshot, image, platform)
            case .paused:
                // VM suspended — host copy is consistent without a guest freeze.
                let snapshot = rootfs.appendingPathExtension("diff-snapshot")
                try FileManager.default.copyItem(at: rootfs, to: snapshot)
                return (id, snapshot, snapshot, image, platform)
            case .stopped:
                return (id, rootfs, nil, image, platform)
            default:
                throw ContainerizationError(
                    .invalidState, message: "container must be running, paused, or stopped to diff")
            }
        }
        defer {
            if let snapshotCleanup = prepared.snapshotCleanup {
                try? FileManager.default.removeItem(at: snapshotCleanup)
            }
        }

        let image = ClientImage(description: prepared.image)
        let imageFs = try await image.getSnapshot(platform: prepared.platform)
        guard imageFs.isBlock else {
            throw ContainerizationError(
                .invalidState, message: "image snapshot for \(prepared.id) is not a block filesystem")
        }

        let containerReader = try EXT4.EXT4Reader(blockDevice: FilePath(prepared.containerBlock.path))
        let imageReader = try EXT4.EXT4Reader(blockDevice: FilePath(imageFs.source))
        let containerInv = try Self.ext4Inventory(containerReader)
        let imageInv = try Self.ext4Inventory(imageReader)

        var changes: [ContainerDiffChange] = []
        for (path, meta) in containerInv {
            if let base = imageInv[path] {
                if base.size != meta.size || base.mtime != meta.mtime {
                    changes.append(ContainerDiffChange(kind: .changed, path: path))
                }
            } else {
                changes.append(ContainerDiffChange(kind: .added, path: path))
            }
        }
        for path in imageInv.keys where containerInv[path] == nil {
            changes.append(ContainerDiffChange(kind: .deleted, path: path))
        }
        changes.sort { $0.path < $1.path }
        return changes
    }

    private static func ext4Inventory(
        _ reader: EXT4.EXT4Reader
    ) throws -> [String: (size: UInt64, mtime: UInt32)] {
        var result: [String: (size: UInt64, mtime: UInt32)] = [:]
        func walk(_ dir: FilePath) throws {
            for name in try reader.listDirectory(dir) {
                let child = dir.join(name)
                let (_, inode) = try reader.stat(child, followSymlinks: false)
                let pathStr = child.description
                // EXT4.FileModeFlag.rawValue is package-internal; use POSIX S_IFMT / S_IFDIR.
                let isDirectory = inode.mode & 0xF000 == 0x4000
                let size = (UInt64(inode.sizeHigh) << 32) | UInt64(inode.sizeLow)
                // Include directories so add/delete/mtime changes surface in `container diff`.
                result[pathStr] = (size, inode.mtime)
                if isDirectory {
                    try walk(child)
                }
            }
        }
        try walk(FilePath("/"))
        return result
    }

    /// Change the user-facing Name of a container (Id stays fixed).
    public func rename(idOrName: String, newName: String) async throws {
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ManagedContainer.nameValid(trimmedName) else {
            throw ContainerizationError(.invalidArgument, message: "container name \(newName) is not a valid container name")
        }
        try await self.lock.withLock(logMetadata: ["acquirer": "\(#function)", "id": "\(idOrName)"]) { [self] context in
            let id = try await self.resolveID(idOrName)
            if let other = await self.containers.first(where: {
                $0.value.snapshot.configuration.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    == trimmedName && $0.key != id
            }) {
                throw ContainerizationError(
                    .exists,
                    message: "container name \(trimmedName) already in use by \(other.key)"
                )
            }
            var state = try await self.getContainerState(id: id, context: context)
            state.snapshot.configuration.name = trimmedName
            try Self.persistConfiguration(state.snapshot.configuration, id: id, containerRoot: self.containerRoot)
            await self.setContainerState(id, state, context: context)
            await self.emitEvent(
                status: "rename", action: "rename", id: id,
                attributes: ["name": trimmedName])
        }
    }

    private static func isInitProcess(id: String, processID: String) -> Bool {
        id == processID
    }

    /// Persist configuration into both the bundle (canonical on load) and runtime-config.json.
    /// Bundle is written first so a failure mid-update still loads the new config next boot.
    private static func persistConfiguration(
        _ configuration: ContainerConfiguration, id: String, containerRoot: URL
    ) throws {
        let path = containerRoot.appendingPathComponent(id)
        try ContainerResource.Bundle(path: path).set(configuration: configuration)
        if let runtime = try? RuntimeConfiguration.readRuntimeConfiguration(from: path) {
            let updated = RuntimeConfiguration(
                path: runtime.path,
                initialFilesystem: runtime.initialFilesystem,
                kernel: runtime.kernel,
                containerConfiguration: configuration,
                containerRootFilesystem: runtime.containerRootFilesystem,
                options: runtime.options,
                runtimeData: runtime.runtimeData
            )
            try updated.writeRuntimeConfiguration()
        }
    }

    /// Block-image named volumes remain exclusive (virtio-blk). Directory-backed
    /// volumes use the shared virtiofs plane and may be RW-mounted by multiple VMs.
    private static func validateExclusiveNamedVolumes(
        mounts: [Filesystem],
        newID: String,
        existing: [String: ContainerState],
        log: Logger
    ) throws {
        let wanted = mounts.compactMap { fs -> (name: String, shared: Bool)? in
            guard fs.isVolume, !fs.options.readonly, let name = fs.volumeName else { return nil }
            return (name, fs.isSharedVirtiofsVolume)
        }
        guard !wanted.isEmpty else { return }
        // Same named volume may appear more than once (different destinations); do not trap.
        let wantedByName = Dictionary(wanted.map { ($0.name, $0.shared) }, uniquingKeysWith: { first, _ in first })

        for (otherID, state) in existing {
            guard otherID != newID else { continue }
            guard state.snapshot.status == .running else { continue }
            for mount in state.snapshot.configuration.mounts {
                guard mount.isVolume, !mount.options.readonly, let name = mount.volumeName else { continue }
                guard let newIsShared = wantedByName[name] else { continue }
                let existingIsShared = mount.isSharedVirtiofsVolume
                if newIsShared && existingIsShared {
                    log.info(
                        "named volume RW share via virtiofs plane",
                        metadata: [
                            "volume": "\(name)",
                            "container": "\(newID)",
                            "peer": "\(otherID)",
                        ]
                    )
                    continue
                }
                throw ContainerizationError(
                    .invalidArgument,
                    message:
                        "named volume \"\(name)\" is already mounted read-write by running container \(otherID). "
                        + "Block-image named volumes are exclusive virtio-blk (single-writer). "
                        + "Recreate the volume without --opt backend=block (default directory/virtiofs plane) "
                        + "to share RW across containers, or use separate volumes / NFS / one writer. "
                        + "See docs/volumes.md."
                )
            }
        }
    }

    /// Get container configuration, either from existing bundle or from RuntimeConfiguration
    private static func getContainerConfiguration(at path: URL) throws -> (ContainerConfiguration, ContainerCreateOptions?) {
        let bundle = ContainerResource.Bundle(path: path)
        do {
            let config = try bundle.configuration
            let options: ContainerCreateOptions? = try? bundle.load(filename: "options.json")
            return (config, options)
        } catch {
            // Bundle doesn't exist or incomplete, try runtime configuration
            // This handles containers that were created but not started yet
            let runtimeConfig = try RuntimeConfiguration.readRuntimeConfiguration(from: path)
            guard let config = runtimeConfig.containerConfiguration else {
                throw ContainerizationError(.internalError, message: "runtime configuration missing container configuration")
            }
            return (config, runtimeConfig.options)
        }
    }
}

extension XPCMessage {
    func signal() throws -> String {
        guard let signal = self.string(key: .signal) else {
            throw ContainerizationError(.invalidArgument, message: "missing signal in xpc message")
        }
        return signal
    }

    func stopOptions() throws -> ContainerStopOptions {
        guard let data = self.dataNoCopy(key: .stopOptions) else {
            throw ContainerizationError(.invalidArgument, message: "missing StopOptions")
        }
        return try JSONDecoder().decode(ContainerStopOptions.self, from: data)
    }

    func setState(_ state: SandboxSnapshot) throws {
        let data = try JSONEncoder().encode(state)
        self.set(key: .snapshot, value: data)
    }

    func stdio() -> [FileHandle?] {
        var handles = [FileHandle?](repeating: nil, count: 3)
        if let stdin = self.fileHandle(key: .stdin) {
            handles[0] = stdin
        }
        if let stdout = self.fileHandle(key: .stdout) {
            handles[1] = stdout
        }
        if let stderr = self.fileHandle(key: .stderr) {
            handles[2] = stderr
        }
        return handles
    }

    func setFileHandle(_ handle: FileHandle) {
        self.set(key: .fd, value: handle)
    }

    func processConfig() throws -> ProcessConfiguration {
        guard let data = self.dataNoCopy(key: .processConfig) else {
            throw ContainerizationError(.invalidArgument, message: "missing process configuration")
        }
        return try JSONDecoder().decode(ProcessConfiguration.self, from: data)
    }
}
