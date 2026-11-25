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

import ContainerNetworkClient
import ContainerOS
import ContainerPersistence
import ContainerResource
import ContainerRuntimeClient
import ContainerXPC
import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import ContainerizationOS
import Foundation
import Logging
import NIO
import NIOFoundationCompat
import SocketForwarder
import Synchronization
import SystemPackage

import struct ContainerizationOCI.Mount
import struct ContainerizationOCI.Process

#if CONTAINER_VMM_CR
import CRContainerization
#endif

/// An XPC service that manages the lifecycle of a single VM-backed container.
public actor RuntimeService {
    private let connection: xpc_connection_t
    private let root: URL
    private let interfaceStrategies: [NetworkInterfaceKey: InterfaceStrategy]
    private var container: ContainerInfo?
    private let monitor: ExitMonitor
    private let eventLoopGroup: any EventLoopGroup
    private var waiters: [String: ExitWaiter] = [:]
    /// Exit status retained so `wait` after teardown still returns the real code
    /// instead of inventing -1 when the waiter map entry is already gone.
    private var exitStatuses: [String: ExitStatus] = [:]
    private let lock: AsyncLock = AsyncLock()
    private let log: Logging.Logger
    private var state: State = .created
    private var processes: [String: ProcessInfo] = [:]
    private var socketForwarders: [SocketForwarderResult] = []
    private var networkSessions: [XPCClientSession] = []

    private static let sshAuthSocketGuestPath = "/var/host-services/ssh-auth.sock"
    private static let sshAuthSocketEnvVar = "SSH_AUTH_SOCK"

    class ExitWaiter {
        public var exitStatus: ExitStatus? = nil
        public var continuations: [CheckedContinuation<ExitStatus, Never>] = []

        public func wait(_ cc: CheckedContinuation<ExitStatus, Never>) {
            if let exitStatus = exitStatus {
                // `doExit` has already been called for this waiter
                cc.resume(returning: exitStatus)
                return
            }
            continuations.append(cc)
        }

        public func doExit(exitStatus: ExitStatus) {
            for cc in continuations {
                cc.resume(returning: exitStatus)
            }

            self.exitStatus = exitStatus
        }
    }

    private static func sshAuthSocketHostUrl(
        config: ContainerConfiguration,
        dynamicEnv: [String: String] = [:],
        log: Logger? = nil
    ) -> URL? {
        guard config.ssh else {
            return nil
        }

        guard let sshSocket = dynamicEnv[Self.sshAuthSocketEnvVar] else {
            log?.warning("ssh forwarding requested but no \(Self.sshAuthSocketEnvVar) found")
            return nil
        }

        return URL(fileURLWithPath: sshSocket)
    }

    public init(
        root: URL,
        interfaceStrategies: [NetworkInterfaceKey: InterfaceStrategy],
        eventLoopGroup: any EventLoopGroup,
        connection: xpc_connection_t,
        log: Logger
    ) {
        self.root = root
        self.interfaceStrategies = interfaceStrategies
        self.log = log
        self.monitor = ExitMonitor(log: log)
        self.eventLoopGroup = eventLoopGroup
        self.connection = connection
    }

    /// Returns an endpoint from an anonymous xpc connection.
    ///
    /// - Parameters:
    ///   - message: An XPC message with no parameters.
    ///
    /// - Returns: An XPC message with the following parameters:
    ///   - endpoint: An XPC endpoint that can be used to communicate
    ///     with the runtime service.
    @Sendable
    public func createEndpoint(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.debug("enter", metadata: ["func": "\(#function)"])
        defer { self.log.debug("exit", metadata: ["func": "\(#function)"]) }

        let endpoint = xpc_endpoint_create(self.connection)
        let reply = message.reply()
        reply.set(key: RuntimeKeys.runtimeServiceEndpoint.rawValue, value: endpoint)
        return reply
    }

    /// Start the VM and the guest agent process for a container.
    ///
    /// - Parameters:
    ///   - message: An XPC message with no parameters.
    ///
    /// - Returns: An XPC message with no parameters.
    @Sendable
    public func bootstrap(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.debug("enter", metadata: ["func": "\(#function)"])
        defer { self.log.debug("exit", metadata: ["func": "\(#function)"]) }

        // Create the bundle if it doesn't exist yet
        if !self.bundleExists(at: self.root) {
            try self.createBundle()
        }

        return try await self.lock.withLock { _ in
            guard await self.state == .created else {
                throw ContainerizationError(
                    .invalidState,
                    message: "container expected to be in created state, got: \(await self.state)"
                )
            }

            let dynamicEnv = try message.dynamicEnv()
            let bundle = ContainerResource.Bundle(path: self.root)
            // Create the log file before payload decode that can throw, so bootstrap
            // failures still leave a bundle log for diagnosis.
            try bundle.createLogFile()
            // Prefer the networkBootstrapInfos invalidArgument over a peerHosts decode
            // error when both are wrong; peerHosts is optional adornment.
            let networkBootstrapInfos = try message.networkBootstrapInfos()
            // peerHosts is optional adornment. Absent key → []; present but undecodable
            // → warn and continue with no peers so a version skew cannot block bootstrap.
            let peerHosts: [PeerHostEntry]
            if message.dataNoCopy(key: RuntimeKeys.peerHosts.rawValue) != nil {
                do {
                    peerHosts = try message.peerHosts()
                } catch {
                    self.log.warning(
                        "ignoring undecodable peerHosts payload during bootstrap",
                        metadata: ["error": "\(error)"])
                    peerHosts = []
                }
            } else {
                peerHosts = []
            }

            var config = try bundle.configuration

            var kernel = try bundle.kernel
            // Built-in defaults keyed by arg name. Each is applied only if the user did not already
            // supply the same key via --kernel-arg, letting custom kernels override them (e.g. lsm=...,bpf).
            let defaultKernelArgs: KeyValuePairs = [
                "oops": "panic",
                "lsm": "lockdown,capability,landlock,yama,apparmor",
            ]
            for (key, value) in defaultKernelArgs {
                guard !kernel.commandLine.kernelArgs.contains(where: { $0.hasPrefix("\(key)=") }) else {
                    continue
                }
                kernel.commandLine.kernelArgs.append("\(key)=\(value)")
            }
            let vmm: any VirtualMachineManager = Self.makeVirtualMachineManager(
                kernel: kernel,
                initialFilesystem: bundle.initialFilesystem.asMount,
                rosetta: config.rosetta,
                logger: self.log
            )

            var sessions: [XPCClientSession] = []
            var attachments: [Attachment] = []
            var interfaces: [Interface] = []
            do {
                for (index, info) in networkBootstrapInfos.enumerated() {
                    let attachmentConfig = config.networks[index]
                    let client = ContainerNetworkClient.NetworkClient(id: attachmentConfig.network, plugin: info.plugin)
                    let session = client.connect()
                    sessions.append(session)
                    var (attachment, additionalData) = try await client.allocate(
                        hostname: attachmentConfig.options.hostname,
                        macAddress: attachmentConfig.options.macAddress,
                        aliases: attachmentConfig.options.aliases,
                        on: session
                    )
                    if let mtu = attachmentConfig.options.mtu {
                        attachment = Attachment(
                            network: attachment.network,
                            hostname: attachment.hostname,
                            ipv4Address: attachment.ipv4Address,
                            ipv4Gateway: attachment.ipv4Gateway,
                            ipv6Address: attachment.ipv6Address,
                            macAddress: attachment.macAddress,
                            mtu: mtu,
                            variant: attachment.variant
                        )
                    }
                    guard let iStrategy = self.interfaceStrategies[NetworkInterfaceKey(plugin: info.plugin, variant: attachment.variant)] else {
                        throw ContainerizationError(
                            .internalError,
                            message: "no available interface strategy for network \(attachment.network), plugin=\(info.plugin) variant=\(attachment.variant ?? "nil")")
                    }
                    let interface = try iStrategy.toInterface(
                        attachment: attachment,
                        interfaceIndex: index,
                        additionalData: additionalData
                    )
                    attachments.append(attachment)
                    interfaces.append(interface)
                }
            } catch {
                for session in sessions { session.close() }
                throw error
            }

            // Dynamically configure the DNS nameserver from a network if no explicit configuration
            if let dns = config.dns, dns.nameservers.isEmpty {
                let defaultNameservers = self.getDefaultNameservers(from: attachments)
                if !defaultNameservers.isEmpty {
                    config.dns = ContainerConfiguration.DNSConfiguration(
                        nameservers: defaultNameservers,
                        domain: dns.domain,
                        searchDomains: dns.searchDomains,
                        options: dns.options
                    )
                }
            }

            let stdio = message.stdio()
            let containerLog = try FileHandle(forWritingTo: bundle.containerLog)
            let stdout = {
                if let h = stdio[1] {
                    return MultiWriter(handles: [h, containerLog])
                }
                return MultiWriter(handles: [containerLog])
            }()

            let stderr: MultiWriter? = {
                if !config.initProcess.terminal {
                    if let h = stdio[2] {
                        return MultiWriter(handles: [h, containerLog])
                    }
                    return MultiWriter(handles: [containerLog])
                }
                return nil
            }()

            let stdin = {
                stdio[0] ?? nil
            }()

            let id = config.id
            let rootfs = try bundle.containerRootfs.asMount
            // Give the VM headroom beyond the container's cgroup limits for the guest kernel,
            // vminitd, and the overhead configured via `config.resources.cpuOverhead`.
            let vmResources = VMResources(
                cpus: config.resources.cpus + config.resources.cpuOverhead,
                memoryInBytes: config.resources.memoryInBytes + VMResources.guestMemoryOverhead
            )
            let container = try LinuxContainer(id, rootfs: rootfs, vmm: vmm, vm: vmResources, logger: self.log) { czConfig in
                try Self.configureContainer(
                    czConfig: &czConfig,
                    config: config,
                    dynamicEnv: dynamicEnv,
                    log: self.log
                )
                czConfig.interfaces = interfaces
                czConfig.process.stdout = stdout
                czConfig.process.stderr = stderr
                czConfig.process.stdin = stdin
                // Point guests at an in-guest hosts-dns helper so nslookup and getaddrinfo
                // both see peer names from /etc/hosts (#1809), forwarding other queries.
                Self.installHostsDNSIfAvailable(czConfig: &czConfig, config: config, log: self.log)
                // Craft a default /etc/hosts, then inject peers already running on shared
                // networks so Compose-ordered stacks can resolve bare service names (#1809).
                var hostsEntries = [Hosts.Entry.localHostIPV4()]
                if !interfaces.isEmpty {
                    let primaryIfaceAddr = interfaces[0].ipv4Address
                    var selfHostnames: [String] = []
                    func appendSelfHostname(_ raw: String?) {
                        guard let raw, !raw.isEmpty else { return }
                        let short =
                            raw.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true)
                            .first.map(String.init) ?? raw
                        guard !selfHostnames.contains(where: { $0.caseInsensitiveCompare(short) == .orderedSame })
                        else { return }
                        selfHostnames.append(short)
                    }
                    appendSelfHostname(czConfig.hostname)
                    appendSelfHostname(config.name)
                    appendSelfHostname(attachments.first?.hostname)
                    appendSelfHostname(id)
                    if let domain = config.domainname?.trimmingCharacters(in: .whitespacesAndNewlines),
                        !domain.isEmpty,
                        let short = czConfig.hostname, !short.isEmpty, !short.contains(".")
                    {
                        let fqdn = "\(short).\(domain)"
                        if !selfHostnames.contains(where: { $0.caseInsensitiveCompare(fqdn) == .orderedSame }) {
                            selfHostnames.append(fqdn)
                        }
                    }
                    hostsEntries.append(
                        Hosts.Entry(
                            ipAddress: primaryIfaceAddr.address.description,
                            hostnames: selfHostnames.isEmpty ? [id] : selfHostnames,
                        ))
                }
                // `--add-host`: explicit entries must win over discovered peers. /etc/hosts resolves
                // first-match, so they go in BEFORE the peers (and are then "claimed", so a peer
                // with the same name is skipped rather than shadowing them).
                for spec in config.extraHosts {
                    guard let split = spec.firstIndex(of: ":") else { continue }
                    hostsEntries.append(
                        Hosts.Entry(
                            ipAddress: String(spec[spec.index(after: split)...]),
                            hostnames: [String(spec[..<split])]
                        ))
                }
                // Skip peer hostnames already claimed by localhost/self so a peer
                // cannot shadow this container's own name. Sort peers so duplicate
                // hostnames resolve deterministically (lower IP / hostname wins).
                var claimedHostnames = Set(
                    hostsEntries.flatMap(\.hostnames).map { $0.lowercased() })
                let orderedPeers = peerHosts.sorted { lhs, rhs in
                    if lhs.ipAddress != rhs.ipAddress { return lhs.ipAddress < rhs.ipAddress }
                    return lhs.hostnames.joined(separator: "\t") < rhs.hostnames.joined(separator: "\t")
                }
                for peer in orderedPeers where !peer.hostnames.isEmpty {
                    let unique = peer.hostnames.compactMap { name -> String? in
                        let lower = name.lowercased()
                        guard claimedHostnames.insert(lower).inserted else { return nil }
                        // Preserve registered case in /etc/hosts; match case-insensitively.
                        return name
                    }
                    guard !unique.isEmpty else { continue }
                    hostsEntries.append(
                        Hosts.Entry(
                            ipAddress: peer.ipAddress,
                            hostnames: unique
                        ))
                }
                czConfig.hosts = Hosts(entries: hostsEntries)
                czConfig.bootLog = BootLog.file(path: bundle.bootlog, append: true)
            }

            let ctrInfo = ContainerInfo(
                container: container,
                config: config,
                attachments: attachments,
                bundle: bundle,
                io: (in: stdin, out: stdout, err: stderr)
            )
            await self.setContainer(ctrInfo)
            await self.setNetworkSessions(sessions)

            do {
                try await container.create()

                try await self.initializeWaiters(for: id)
                try await self.monitor.registerProcess(id: config.id, onExit: self.onContainerExit)
                if !container.interfaces.isEmpty {
                    try await self.startSocketForwarders(attachment: attachments[0], publishedPorts: config.publishedPorts)
                }
                await self.setState(.booted)
            } catch {
                do {
                    try await self.cleanUpContainer(containerInfo: ctrInfo)
                    await self.setState(.stopped)
                } catch {
                    self.log.error("failed to clean up container", metadata: ["error": "\(error)"])
                }
                throw Self.annotateMountErrors(error, mounts: config.mounts)
            }
            return message.reply()
        }
    }

    /// Start the container workload inside the virtual machine.
    ///
    /// - Parameters:
    ///   - message: An XPC message with the following parameters:
    ///     - id: A client identifier for the process.
    ///     - stdio: An array of file handles for standard input, output, and error.
    ///
    /// - Returns: An XPC message with no parameters.
    @Sendable
    public func startProcess(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.debug("enter", metadata: ["func": "\(#function)"])
        defer { self.log.debug("exit", metadata: ["func": "\(#function)"]) }

        return try await self.lock.withLock { lock in
            let id = try message.id()
            let containerInfo = try await self.getContainer()
            let containerId = containerInfo.container.id
            if id == containerId {
                try await self.startInitProcess(lock: lock)
                await self.setState(.running)
            } else {
                try await self.startExecProcess(processId: id, lock: lock)
            }
            return message.reply()
        }
    }

    /// Get statistics for the container.
    ///
    /// - Parameters:
    ///   - message: An XPC message with the following parameters:
    ///     - id: A client identifier for the process.
    ///     - stdio: An array of file handles for standard input, output, and error.
    ///
    /// - Returns: An XPC message with the following parameters:
    ///   - statistics: JSON serialization of the `ContainerStats`.
    @Sendable
    public func statistics(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.debug("enter", metadata: ["func": "\(#function)"])
        defer { self.log.debug("exit", metadata: ["func": "\(#function)"]) }

        return try await self.lock.withLock { lock in
            let containerInfo = try await self.getContainer()
            let stats = try await containerInfo.container.statistics()

            let containerStats = ContainerStats(
                id: stats.id,
                memoryUsageBytes: stats.memory?.usageBytes,
                memoryLimitBytes: stats.memory?.limitBytes,
                cpuUsageUsec: stats.cpu?.usageUsec,
                networkRxBytes: stats.networks?.reduce(0) { $0 + $1.receivedBytes },
                networkTxBytes: stats.networks?.reduce(0) { $0 + $1.transmittedBytes },
                blockReadBytes: stats.blockIO?.devices.reduce(0) { $0 + $1.readBytes },
                blockWriteBytes: stats.blockIO?.devices.reduce(0) { $0 + $1.writeBytes },
                numProcesses: stats.process?.current
            )

            let reply = message.reply()
            let data = try JSONEncoder().encode(containerStats)
            reply.set(key: RuntimeKeys.statistics.rawValue, value: data)
            return reply
        }
    }

    /// Shutdown the RuntimeService.
    ///
    /// - Parameters:
    ///   - message: An XPC message with no parameters.
    ///
    /// - Returns: An XPC message with no parameters.
    @Sendable
    public func shutdown(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.debug("enter", metadata: ["func": "\(#function)"])
        defer { self.log.debug("exit", metadata: ["func": "\(#function)"]) }

        return try await self.lock.withLock { _ in
            switch await self.state {
            case .created, .stopped, .stopping:
                await self.setState(.shuttingDown)

            default:
                throw ContainerizationError(
                    .invalidState,
                    message: "cannot shutdown: container is not stopped"
                )
            }

            return message.reply()
        }
    }

    /// Create a process inside the virtual machine for the container.
    ///
    /// Use this procedure to run ad hoc processes in the virtual
    /// machine (`container exec`).
    ///
    /// - Parameters:
    ///   - message: An XPC message with the following parameters:
    ///     - id: A client identifier for the process.
    ///     - processConfig: JSON serialization of the `ProcessConfiguration`
    ///       containing the process attributes.
    ///
    /// - Returns: An XPC message with no parameters.
    @Sendable
    public func createProcess(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.debug("enter", metadata: ["func": "\(#function)"])
        defer { self.log.debug("exit", metadata: ["func": "\(#function)"]) }

        return try await self.lock.withLock { [self] _ in
            switch await self.state {
            case .running, .booted:
                let id = try message.id()
                let config = try message.processConfig()
                let stdio = message.stdio()

                try await self.addNewProcess(id, config, stdio)

                try await self.initializeWaiters(for: id)
                do {
                    try await self.monitor.registerProcess(
                        id: id,
                        onExit: { id, exitStatus in
                            await self.releaseWaiters(for: id, status: exitStatus)
                            // Remove first so a delete() failure cannot leak the map entry.
                            guard let process = await self.takeProcess(id) else {
                                throw ContainerizationError(
                                    .invalidState,
                                    message: "ProcessInfo missing for process \(id)"
                                )
                            }
                            try await process.delete()
                        }
                    )
                } catch {
                    await self.releaseWaiters(for: id, status: ExitStatus(exitCode: -1))
                    await self.dropProcessClosingIO(id)
                    throw error
                }

                return message.reply()
            default:
                throw ContainerizationError(
                    .invalidState,
                    message: "cannot exec: container is not running"
                )
            }
        }
    }

    /// Return the state for the sandbox and its containers.
    ///
    /// - Parameters:
    ///   - message: An XPC message with no parameters.
    ///
    /// - Returns: An XPC message with the following parameters:
    ///   - snapshot: The JSON serialization of the `SandboxSnapshot`
    ///     that contains the state information.
    @Sendable
    public func state(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.debug("enter", metadata: ["func": "\(#function)"])
        defer { self.log.debug("exit", metadata: ["func": "\(#function)"]) }

        var status: RuntimeStatus = .unknown
        var networks: [Attachment] = []
        var cs: ContainerSnapshot?

        switch state {
        case .created, .stopped, .booted, .shuttingDown:
            status = .stopped
        case .stopping:
            status = .stopping
        case .paused:
            let ctr = try getContainer()
            status = .paused
            networks = ctr.attachments
            cs = ContainerSnapshot(
                configuration: ctr.config,
                status: RuntimeStatus.paused,
                networks: networks
            )
        case .running:
            let ctr = try getContainer()

            status = .running
            networks = ctr.attachments
            cs = ContainerSnapshot(
                configuration: ctr.config,
                status: RuntimeStatus.running,
                networks: networks
            )
        }

        let reply = message.reply()
        try reply.setState(
            .init(
                status: status,
                networks: networks,
                containers: cs != nil ? [cs!] : []
            )
        )
        return reply
    }

    /// Stop the container workload, any ad hoc processes, and the underlying
    /// virtual machine.
    ///
    /// - Parameters:
    ///   - message: An XPC message with the following parameters:
    ///     - stopOptions: JSON serialization of `ContainerStopOptions`
    ///       that modify stop behavior.
    ///
    /// - Returns: An XPC message with no parameters.
    @Sendable
    public func stop(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.debug("enter", metadata: ["func": "\(#function)"])
        defer { self.log.debug("exit", metadata: ["func": "\(#function)"]) }

        let stopOptions = try message.stopOptions()
        let signal = try Signal(stopOptions.signal ?? "SIGTERM")
        let timeout: Duration = .seconds(stopOptions.timeoutInSeconds)
        let crBackend = Self.isCRBackend()

        // Prefer cooperative CR STOP under the lock. If dials wedge the lock,
        // a parallel watchdog SIGKILLs helpers after 2s so stop can proceed —
        // without pre-killing (which skipped cooperative STOP entirely).
        return try await withThrowingTaskGroup(of: XPCMessage.self) { group in
            group.addTask {
                try await self.lock.withLock { _ in
                    switch await self.state {
                    case .running, .booted, .paused:
                        var skipGraceful = false
                        if case .paused = await self.state {
                            do {
                                let ctr = try await self.getContainer()
                                try await ctr.container.withVirtualMachineInstance { vm in
                                    try await vm.resume()
                                }
                                await self.setState(.running)
                            } catch {
                                self.log.error(
                                    "failed to resume paused VM before stop; forcing cleanup",
                                    metadata: ["error": "\(error)"]
                                )
                                skipGraceful = true
                                await self.setState(.stopping)
                            }
                        }
                        if await self.state != .stopping {
                            await self.setState(.stopping)
                        }

                        let ctr = try await self.getContainer()
                        let exitStatus: ExitStatus
                        if skipGraceful {
                            exitStatus = ExitStatus(exitCode: 255)
                            if crBackend {
                                Self.killCRGuestHelperChildren()
                            }
                        } else {
                            exitStatus = try await self.gracefulStopContainer(
                                ctr.container,
                                signal: signal,
                                timeout: timeout
                            )
                        }

                        do {
                            if case .stopped = await self.state {
                                return message.reply()
                            }
                            try await self.cleanUpContainer(containerInfo: ctr, exitStatus: exitStatus)
                        } catch {
                            self.log.error("failed to clean up container", metadata: ["error": "\(error)"])
                        }
                        await self.setState(.stopped)
                    default:
                        break
                    }
                    return message.reply()
                }
            }
            if crBackend {
                group.addTask {
                    try await Task.sleep(for: .seconds(2))
                    Self.killCRGuestHelperChildren()
                    // Park until the lock task finishes (or group cancels).
                    try await Task.sleep(for: .seconds(600))
                    throw CancellationError()
                }
            }
            guard let reply = try await group.next() else {
                throw ContainerizationError(.internalError, message: "stop returned no reply")
            }
            group.cancelAll()
            return reply
        }
    }

    /// Pause (suspend) the container's virtual machine.
    @Sendable
    public func pause(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.debug("enter", metadata: ["func": "\(#function)"])
        defer { self.log.debug("exit", metadata: ["func": "\(#function)"]) }

        return try await self.lock.withLock { _ in
            switch await self.state {
            case .running:
                let ctr = try await self.getContainer()
                try await ctr.container.withVirtualMachineInstance { vm in
                    try await vm.pause()
                }
                await self.setState(.paused)
                return message.reply()
            case .paused:
                return message.reply()
            default:
                throw ContainerizationError(
                    .invalidState,
                    message: "cannot pause: container is not running"
                )
            }
        }
    }

    /// Resume a paused container's virtual machine.
    @Sendable
    public func resume(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.debug("enter", metadata: ["func": "\(#function)"])
        defer { self.log.debug("exit", metadata: ["func": "\(#function)"]) }

        return try await self.lock.withLock { _ in
            switch await self.state {
            case .paused:
                let ctr = try await self.getContainer()
                try await ctr.container.withVirtualMachineInstance { vm in
                    try await vm.resume()
                }
                await self.setState(.running)
                return message.reply()
            case .running:
                return message.reply()
            default:
                throw ContainerizationError(
                    .invalidState,
                    message: "cannot unpause: container is not paused"
                )
            }
        }
    }

    /// Hotplug a virtio-blk image onto a running CR-backed container (C3).
    ///
    /// Calls ``CRVirtualMachineInstance/hotplug(_:id:)``. VZ / non-CR backends return unsupported.
    @Sendable
    public func hotplugBlock(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.debug("enter", metadata: ["func": "\(#function)"])
        defer { self.log.debug("exit", metadata: ["func": "\(#function)"]) }

        return try await self.lock.withLock { _ in
            guard case .running = await self.state else {
                throw ContainerizationError(
                    .invalidState,
                    message: "cannot hotplug block: container is not running"
                )
            }
            guard Self.isCRBackend() else {
                throw ContainerizationError(
                    .unsupported,
                    message: "block hotplug requires CR VMM backend"
                )
            }
            guard let path = message.string(key: RuntimeKeys.hotplugBlockPath.rawValue), !path.isEmpty else {
                throw ContainerizationError(.invalidArgument, message: "missing hotplugBlockPath")
            }
            let id = message.string(key: RuntimeKeys.hotplugBlockID.rawValue) ?? UUID().uuidString
            let mount = Containerization.Mount.block(
                format: "ext4",
                source: path,
                destination: "/mnt/hotplug-\(id)",
                options: []
            )
            #if CONTAINER_VMM_CR
            let ctr = try await self.getContainer()
            try await ctr.container.withVirtualMachineInstance { vm in
                guard let cr = vm as? CRVirtualMachineInstance else {
                    throw ContainerizationError(
                        .unsupported,
                        message: "block hotplug requires CRVirtualMachineInstance"
                    )
                }
                _ = try await cr.hotplug(mount, id: id)
            }
            self.log.info("hotplugBlock ok", metadata: ["id": "\(id)", "path": "\(path)"])
            return message.reply()
            #else
            throw ContainerizationError(
                .unsupported,
                message: "runtime was not built with CONTAINER_VMM_CR"
            )
            #endif
        }
    }

    /// Hotplug a network interface onto a running container (R1 / F4).
    ///
    /// Allocates an attachment, calls CR or VZ ``hotplugNetwork``, then configures
    /// `ethN` via the guest agent.
    @Sendable
    public func hotplugNetwork(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.debug("enter", metadata: ["func": "\(#function)"])
        defer { self.log.debug("exit", metadata: ["func": "\(#function)"]) }

        return try await self.lock.withLock { _ in
            guard case .running = await self.state else {
                throw ContainerizationError(
                    .invalidState,
                    message: "cannot hotplug network: container is not running"
                )
            }

            guard let attachmentData = message.dataNoCopy(key: RuntimeKeys.networkAttachment.rawValue) else {
                throw ContainerizationError(.invalidArgument, message: "missing networkAttachment")
            }
            let attachmentConfig = try JSONDecoder().decode(AttachmentConfiguration.self, from: attachmentData)
            let infos = try message.networkBootstrapInfos()
            guard let info = infos.first else {
                throw ContainerizationError(.invalidArgument, message: "missing networkBootstrapInfos")
            }

            var ctr = try await self.getContainer()
            let index = ctr.attachments.count
            let client = ContainerNetworkClient.NetworkClient(id: attachmentConfig.network, plugin: info.plugin)
            let session = client.connect()
            var (attachment, additionalData): (Attachment, XPCMessage?)
            do {
                (attachment, additionalData) = try await client.allocate(
                    hostname: attachmentConfig.options.hostname,
                    macAddress: attachmentConfig.options.macAddress,
                    aliases: attachmentConfig.options.aliases,
                    on: session
                )
                if let mtu = attachmentConfig.options.mtu {
                    attachment = Attachment(
                        network: attachment.network,
                        hostname: attachment.hostname,
                        ipv4Address: attachment.ipv4Address,
                        ipv4Gateway: attachment.ipv4Gateway,
                        ipv6Address: attachment.ipv6Address,
                        macAddress: attachment.macAddress,
                        mtu: mtu,
                        variant: attachment.variant
                    )
                }
            } catch {
                session.close()
                throw error
            }

            guard let iStrategy = self.interfaceStrategies[NetworkInterfaceKey(plugin: info.plugin, variant: attachment.variant)] else {
                session.close()
                throw ContainerizationError(
                    .internalError,
                    message: "no available interface strategy for network \(attachment.network)"
                )
            }
            let interface = try iStrategy.toInterface(
                attachment: attachment,
                interfaceIndex: index,
                additionalData: additionalData
            )

            do {
                try await ctr.container.withVirtualMachineInstance { vm in
                    #if CONTAINER_VMM_CR
                    if let cr = vm as? CRVirtualMachineInstance {
                        try await cr.hotplugNetwork(interface: interface)
                        return
                    }
                    #endif
                    // VZ spare-NIC hotplug exists only in the CRVirtualization containerization
                    // fork; stock containerization has no such API, so stock builds fall through
                    // to the "unsupported" error and callers restart the container instead.
                    #if CONTAINER_VMM_CR
                    if let vz = vm as? VZVirtualMachineInstance {
                        try await vz.hotplugNetwork(interface: interface)
                        return
                    }
                    #endif
                    throw ContainerizationError(
                        .unsupported,
                        message: "network hotplug unsupported for this VMM instance"
                    )
                }
            } catch {
                session.close()
                throw error
            }

            let ifaceName = "eth\(index)"
            try await ctr.container.withVirtualMachineInstance { vm in
                let agent = try await vm.dialAgent()
                do {
                    try await agent.addressAdd(
                        name: ifaceName,
                        address: .init(ipv4Address: interface.ipv4Address, ipv6Address: interface.ipv6Address)
                    )
                    try await agent.up(name: ifaceName, mtu: interface.mtu)
                    // Secondary NICs do not steal the default route.
                    try await agent.close()
                } catch {
                    try? await agent.close()
                    throw error
                }
            }

            ctr.attachments.append(attachment)
            await self.appendNetworkSession(session)
            await self.setContainer(ctr)
            self.log.info("hotplugNetwork ok", metadata: ["iface": "\(ifaceName)", "network": "\(attachment.network)"])
            return message.reply()
        }
    }

    /// Unplug a secondary hotplugged network (R1). Brings the guest iface down and
    /// clears the VZ spare attachment (CR leaves the MMIO device; guest iface is downed).
    @Sendable
    public func unplugNetwork(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.debug("enter", metadata: ["func": "\(#function)"])
        defer { self.log.debug("exit", metadata: ["func": "\(#function)"]) }

        return try await self.lock.withLock { _ in
            guard case .running = await self.state else {
                throw ContainerizationError(
                    .invalidState,
                    message: "cannot unplug network: container is not running"
                )
            }
            guard let networkID = message.string(key: RuntimeKeys.unplugNetworkID.rawValue), !networkID.isEmpty else {
                throw ContainerizationError(.invalidArgument, message: "missing unplugNetworkID")
            }

            var ctr = try await self.getContainer()
            guard let index = ctr.attachments.firstIndex(where: { $0.network == networkID }) else {
                throw ContainerizationError(
                    .notFound,
                    message: "attachment for network \(networkID) not found in runtime"
                )
            }
            if index == 0 {
                throw ContainerizationError(
                    .invalidState,
                    message: "cannot unplug primary network \(networkID) via hotplug path"
                )
            }
            let ifaceName = "eth\(index)"
            let slotOffset = index - 1

            try await ctr.container.withVirtualMachineInstance { vm in
                let agent = try await vm.dialAgent()
                do {
                    try await agent.down(name: ifaceName)
                    try await agent.close()
                } catch {
                    try? await agent.close()
                    // Best-effort: still clear host attachment even if guest down fails.
                    self.log.warning(
                        "unplugNetwork guest down failed",
                        metadata: ["iface": "\(ifaceName)", "error": "\(error)"]
                    )
                }
                #if CONTAINER_VMM_CR
                if let vz = vm as? VZVirtualMachineInstance {
                    try await vz.unplugNetwork(slotOffset: slotOffset)
                }
                if let cr = vm as? CRVirtualMachineInstance {
                    try await cr.unplugNetwork(slotOffset: slotOffset)
                }
                #endif
            }

            ctr.attachments.remove(at: index)
            await self.setContainer(ctr)
            self.log.info("unplugNetwork ok", metadata: ["iface": "\(ifaceName)", "network": "\(networkID)"])
            return message.reply()
        }
    }

    /// Signal a process running in the virtual machine.
    ///
    /// - Parameters:
    ///   - message: An XPC message with the following parameters:
    ///     - id: The process identifier.
    ///     - signal: The signal value.
    ///
    /// - Returns: An XPC message with no parameters.
    @Sendable
    public func kill(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.debug("enter", metadata: ["func": "\(#function)"])
        defer { self.log.debug("exit", metadata: ["func": "\(#function)"]) }

        let id = try message.id()
        let signal = try Signal(message.signal())

        try await self.lock.withLock { [self] _ in
            switch await self.state {
            case .running:
                let ctr = try await getContainer()
                if id != ctr.container.id {
                    guard let processInfo = await self.processes[id] else {
                        throw ContainerizationError(.invalidState, message: "process \(id) does not exist")
                    }

                    guard let proc = processInfo.process else {
                        throw ContainerizationError(.invalidState, message: "process \(id) not started")
                    }
                    try await proc.kill(signal)
                    return
                }

                try await ctr.container.kill(signal)
            default:
                throw ContainerizationError(
                    .invalidState,
                    message: "cannot kill: container is not running"
                )
            }
        }

        // SIGKILL is guaranteed by the kernel to terminate the target, so block
        // until we observe the exit.
        if signal == .kill {
            _ = await withCheckedContinuation { cc in
                self.waitForExit(id: id, cont: cc)
            }
        }

        return message.reply()
    }

    /// Resize the terminal for a process.
    ///
    /// - Parameters:
    ///   - message: An XPC message with the following parameters:
    ///     - id: The process identifier.
    ///     - width: The terminal width.
    ///     - height: The terminal height.
    ///
    /// - Returns: An XPC message with no parameters.
    @Sendable
    public func resize(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.trace("enter", metadata: ["func": "\(#function)"])
        defer { self.log.trace("exit", metadata: ["func": "\(#function)"]) }

        switch self.state {
        case .running:
            let id = try message.id()
            let ctr = try getContainer()
            let width = message.uint64(key: RuntimeKeys.width.rawValue)
            let height = message.uint64(key: RuntimeKeys.height.rawValue)

            if id != ctr.container.id {
                guard let processInfo = self.processes[id] else {
                    throw ContainerizationError(
                        .invalidState,
                        message: "process \(id) does not exist"
                    )
                }

                guard let proc = processInfo.process else {
                    throw ContainerizationError(
                        .invalidState,
                        message: "process \(id) not started"
                    )
                }

                guard width <= UInt64(UInt16.max), height <= UInt64(UInt16.max) else {
                    throw ContainerizationError(
                        .invalidArgument,
                        message: "terminal size \(width)x\(height) exceeds UInt16"
                    )
                }
                try await proc.resize(
                    to: .init(
                        width: UInt16(width),
                        height: UInt16(height))
                )
            } else {
                guard width <= UInt64(UInt16.max), height <= UInt64(UInt16.max) else {
                    throw ContainerizationError(
                        .invalidArgument,
                        message: "terminal size \(width)x\(height) exceeds UInt16"
                    )
                }
                try await ctr.container.resize(
                    to: .init(
                        width: UInt16(width),
                        height: UInt16(height))
                )
            }

            return message.reply()
        default:
            throw ContainerizationError(
                .invalidState,
                message: "cannot resize: container is not running"
            )
        }
    }

    /// Wait for a process.
    ///
    /// - Parameters:
    ///   - message: An XPC message with the following parameters:
    ///     - id: The process identifier.
    ///
    /// - Returns: An XPC message with the following parameters:
    ///   - exitCode: The exit code for the process.
    @Sendable
    public func wait(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.debug("enter", metadata: ["func": "\(#function)"])
        defer { self.log.debug("exit", metadata: ["func": "\(#function)"]) }

        guard let id = message.string(key: RuntimeKeys.id.rawValue) else {
            throw ContainerizationError(.invalidArgument, message: "missing id in wait xpc message")
        }

        let exitStatus = await withCheckedContinuation { cc in
            self.waitForExit(id: id, cont: cc)
        }
        let reply = message.reply()
        reply.set(key: RuntimeKeys.exitCode.rawValue, value: Int64(exitStatus.exitCode))
        reply.set(key: RuntimeKeys.exitedAt.rawValue, value: exitStatus.exitedAt)
        return reply
    }

    /// Copy a file or directory from the host into the container.
    ///
    /// - Parameters:
    ///   - message: An XPC message with the following parameters:
    ///     - sourcePath: The host path to copy from.
    ///     - destinationPath: The container path to copy to.
    ///     - fileMode: The file permissions mode (UInt64).
    ///
    /// - Returns: An XPC message with no parameters.
    @Sendable
    public func copyIn(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.info("`copyIn` xpc handler")
        switch self.state {
        case .running, .booted:
            guard let source = message.string(key: RuntimeKeys.sourcePath.rawValue) else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "no source path supplied for copyIn"
                )
            }
            guard let destination = message.string(key: RuntimeKeys.destinationPath.rawValue) else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "no destination path supplied for copyIn"
                )
            }
            let mode = UInt32(message.uint64(key: RuntimeKeys.fileMode.rawValue))
            let createParents = message.bool(key: RuntimeKeys.createParents.rawValue)

            let ctr = try getContainer()
            try await ctr.container.copyIn(
                from: URL(fileURLWithPath: source),
                to: URL(fileURLWithPath: destination),
                mode: mode,
                createParents: createParents
            )

            return message.reply()
        default:
            throw ContainerizationError(
                .invalidState,
                message: "cannot copyIn: container is not running"
            )
        }
    }

    /// Copy a file or directory from the container to the host.
    ///
    /// - Parameters:
    ///   - message: An XPC message with the following parameters:
    ///     - sourcePath: The container path to copy from.
    ///     - destinationPath: The host path to copy to.
    ///
    /// - Returns: An XPC message with no parameters.
    @Sendable
    public func copyOut(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.info("`copyOut` xpc handler")
        switch self.state {
        case .running, .booted:
            guard let source = message.string(key: RuntimeKeys.sourcePath.rawValue) else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "no source path supplied for copyOut"
                )
            }
            guard let destination = message.string(key: RuntimeKeys.destinationPath.rawValue) else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "no destination path supplied for copyOut"
                )
            }

            let createParents = message.bool(key: RuntimeKeys.createParents.rawValue)

            let ctr = try getContainer()
            try await ctr.container.copyOut(
                from: URL(fileURLWithPath: source),
                to: URL(fileURLWithPath: destination),
                createParents: createParents
            )

            return message.reply()
        default:
            throw ContainerizationError(
                .invalidState,
                message: "cannot copyOut: container is not running"
            )
        }
    }

    /// Snapshot the container's root filesystem.
    ///
    /// When the container is running, freeze/thaw around the copy for consistency.
    /// When it is not running, copy directly without freeze/thaw.
    ///
    /// - Parameters:
    ///   - message: An XPC message with the following parameters:
    ///     - imagePath: The path to the source filesystem image.
    ///     - destinationPath: The path where the snapshot will be written.
    ///
    /// - Returns: An XPC message with no parameters.
    @Sendable
    public func snapshotDisk(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.info("`snapshotDisk` xpc handler")
        switch self.state {
        case .running, .booted:
            guard let imagePath = message.string(key: RuntimeKeys.imagePath.rawValue) else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "no image path supplied for snapshotDisk"
                )
            }
            guard let destinationPath = message.string(key: RuntimeKeys.destinationPath.rawValue) else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "no destination path supplied for snapshotDisk"
                )
            }

            let ctr = try getContainer()
            let shouldFreeze = self.state == .running

            if shouldFreeze {
                try await ctr.container.filesystemOperation(operation: .freeze, path: "/")
            }

            do {
                // Copy off the actor so large rootfs snapshots do not stall other XPC handlers.
                try await Task.detached(priority: .utility) {
                    try FileManager.default.copyItem(atPath: imagePath, toPath: destinationPath)
                }.value
            } catch {
                if shouldFreeze {
                    do {
                        try await ctr.container.filesystemOperation(operation: .thaw, path: "/")
                    } catch let thawError {
                        self.log.error(
                            "failed to thaw filesystem after snapshotDisk error",
                            metadata: [
                                "copyError": "\(error)",
                                "thawError": "\(thawError)",
                            ])
                        throw ContainerizationError(
                            .internalError,
                            message: "snapshotDisk failed (\(error)) and thaw failed (\(thawError))"
                        )
                    }
                }
                throw error
            }

            if shouldFreeze {
                do {
                    try await ctr.container.filesystemOperation(operation: .thaw, path: "/")
                } catch {
                    // Snapshot already landed; thaw failure must not leave the FS frozen silently.
                    self.log.error(
                        "failed to thaw filesystem after successful snapshotDisk",
                        metadata: ["error": "\(error)"]
                    )
                    throw ContainerizationError(
                        .internalError,
                        message: "snapshot written but thaw failed: \(error)"
                    )
                }
            }

            return message.reply()
        default:
            throw ContainerizationError(
                .invalidState,
                message: "cannot snapshot disk: container is not running"
            )
        }
    }

    /// Clean up unused space in the container filesystem.
    ///
    /// - Parameters:
    ///   - message: An XPC message with the following parameters:
    ///     - id: The container ID.
    ///
    /// - Returns: An XPC message with no parameters.
    @Sendable
    public func clean(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.info("`clean` xpc handler")
        switch self.state {
        case .running:
            guard let id = message.string(key: RuntimeKeys.id.rawValue) else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "no id supplied for clean"
                )
            }

            let ctr = try getContainer()

            var targets: [String] = []
            if !ctr.config.readOnly {
                targets.append("/")
            }
            for mount in ctr.config.mounts where mount.isBlock && !mount.options.readonly {
                targets.append(mount.destination)
            }

            var failed: [String] = []
            for path in targets {
                do {
                    try await ctr.container.filesystemOperation(operation: .trim, path: path)
                } catch {
                    self.log.error("failed to clean mount", metadata: ["path": "\(path)", "error": "\(error)"])
                    failed.append("\(path) (\(error))")
                }
            }

            guard failed.isEmpty else {
                throw ContainerizationError(
                    .internalError,
                    message: "failed to clean mounts in \(id): \(failed.joined(separator: ", "))"
                )
            }

            return message.reply()
        default:
            throw ContainerizationError(
                .invalidState,
                message: "cannot clean: container is not running"
            )
        }
    }

    /// Dial a vsock port on the virtual machine.
    ///
    /// - Parameters:
    ///   - message: An XPC message with the following parameters:
    ///     - port: The port number.
    ///
    /// - Returns: An XPC message with the following parameters:
    ///   - fd: The file descriptor for the vsock.
    @Sendable
    public func dial(_ message: XPCMessage) async throws -> XPCMessage {
        self.log.debug("enter", metadata: ["func": "\(#function)"])
        defer { self.log.debug("exit", metadata: ["func": "\(#function)"]) }

        switch self.state {
        case .running, .booted:
            let port = message.uint64(key: RuntimeKeys.port.rawValue)
            guard port > 0 else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "no vsock port supplied for dial"
                )
            }

            let ctr = try getContainer()
            let fh = try await ctr.container.dialVsock(port: UInt32(port))

            let reply = message.reply()
            reply.set(key: RuntimeKeys.fd.rawValue, value: fh)
            return reply
        default:
            throw ContainerizationError(
                .invalidState,
                message: "cannot dial: container is not running"
            )
        }
    }

    private func startInitProcess(lock: AsyncLock.Context) async throws {
        let info = try self.getContainer()
        let container = info.container
        let id = container.id

        guard self.state == .booted else {
            throw ContainerizationError(
                .invalidState,
                message: "container expected to be in booted state, got: \(self.state)"
            )
        }

        do {
            let io = info.io

            try await container.start()
            let waitFunc: ExitMonitor.WaitHandler = {
                // Match exec waitFunc: always close writers even when wait throws.
                defer {
                    try? io.out?.close()
                    try? io.err?.close()
                    try? io.in?.close()
                }
                return try await container.wait()
            }
            try await self.monitor.track(id: id, waitingOn: waitFunc)
        } catch {
            try? await self.cleanUpContainer(containerInfo: info)
            self.setState(.stopped)
            throw error
        }
    }

    private func startExecProcess(processId id: String, lock: AsyncLock.Context) async throws {
        let container = try self.getContainer().container
        guard let processInfo = self.processes[id] else {
            throw ContainerizationError(.notFound, message: "process with id \(id)")
        }

        let containerInfo = try self.getContainer()
        let czConfig = try self.configureProcessConfig(
            config: processInfo.config,
            stdio: processInfo.io,
            containerConfig: containerInfo.config,
        )

        do {
            let process = try await container.exec(id, configuration: czConfig)
            try self.setUnderlyingProcess(id, process)

            try await process.start()

            let waitFunc: ExitMonitor.WaitHandler = {
                // Always close stdio ends so ProcessIO.wait observes EOF even if
                // process.wait throws (otherwise CLI hits CancellationError after 3s).
                defer {
                    for handle in processInfo.io { try? handle?.close() }
                }
                return try await process.wait()
            }
            try await self.monitor.track(id: id, waitingOn: waitFunc)
        } catch {
            // Resume any waiters, drop the orphaned exec entry, and close stdio.
            self.releaseWaiters(for: id, status: ExitStatus(exitCode: -1))
            self.dropProcessClosingIO(id)
            throw error
        }
    }

    private func startSocketForwarders(attachment: Attachment, publishedPorts: [PublishPort]) async throws {
        guard !publishedPorts.isEmpty else {
            return
        }
        LocalNetworkPrivacy.triggerLocalNetworkPrivacyAlert()

        var forwarders: [SocketForwarderResult] = []
        guard !publishedPorts.hasOverlaps() else {
            throw ContainerizationError(.invalidArgument, message: "host ports for different publish port specs may not overlap")
        }

        do {
            try await withThrowingTaskGroup(of: SocketForwarderResult.self) { group in
                for publishedPort in publishedPorts {
                    for index in 0..<publishedPort.count {
                        let proxyAddress = try SocketAddress(ipAddress: publishedPort.hostAddress.description, port: Int(publishedPort.hostPort + index))
                        let containerIPAddress: String
                        switch publishedPort.hostAddress {
                        case .v4(_):
                            containerIPAddress = attachment.ipv4Address.address.description
                        case .v6(_):
                            guard let ipv6Address = attachment.ipv6Address else {
                                throw ContainerizationError(.invalidState, message: "cannot configure IPv6 port forwarding for container with unknown IPv6 address")
                            }
                            containerIPAddress = ipv6Address.address.description
                        }
                        let serverAddress = try SocketAddress(ipAddress: containerIPAddress, port: Int(publishedPort.containerPort + index))
                        log.info(
                            "creating forwarder for",
                            metadata: [
                                "proxy": "\(proxyAddress)",
                                "server": "\(serverAddress)",
                                "protocol": "\(publishedPort.proto)",
                            ])
                        group.addTask {
                            let forwarder: SocketForwarder
                            switch publishedPort.proto {
                            case .tcp:
                                forwarder = try TCPForwarder(
                                    proxyAddress: proxyAddress,
                                    serverAddress: serverAddress,
                                    eventLoopGroup: self.eventLoopGroup,
                                    log: self.log
                                )
                            case .udp:
                                forwarder = try UDPForwarder(
                                    proxyAddress: proxyAddress,
                                    serverAddress: serverAddress,
                                    eventLoopGroup: self.eventLoopGroup,
                                    log: self.log
                                )
                            }
                            do {
                                return try await forwarder.run().get()
                            } catch let error as IOError where error.errnoCode == EACCES {
                                if let port = proxyAddress.port, port < 1024 {
                                    throw ContainerizationError(
                                        .invalidArgument,
                                        message: "Permission denied while binding to host port \(port). Binding to ports below 1024 requires root privileges."
                                    )
                                }
                                throw error
                            }
                        }
                    }
                }
                do {
                    for try await result in group {
                        forwarders.append(result)
                    }
                } catch {
                    // Cancel siblings, then drain already-finished results so the
                    // outer catch can close every bound forwarder.
                    group.cancelAll()
                    while let next = await group.nextResult() {
                        if case .success(let forwarder) = next {
                            forwarders.append(forwarder)
                        }
                    }
                    throw error
                }
            }
        } catch {
            // Close any forwarders that bound before a sibling task failed.
            for forwarder in forwarders {
                forwarder.close()
                try? await forwarder.wait()
            }
            throw error
        }

        self.socketForwarders = forwarders
    }

    private func stopSocketForwarders() async {
        log.info("closing forwarders")
        for forwarder in self.socketForwarders {
            forwarder.close()
            try? await forwarder.wait()
        }
        log.info("closed forwarders")
    }

    private func onContainerExit(id: String, exitStatus: ExitStatus) async throws {
        self.log.info("init process exited", metadata: ["status": "\(exitStatus)"])

        try await self.lock.withLock { [self] _ in
            let ctrInfo = try await getContainer()

            switch await self.state {
            case .stopped, .stopping:
                return
            default:
                break
            }

            do {
                try await cleanUpContainer(containerInfo: ctrInfo, exitStatus: exitStatus)
            } catch {
                self.log.error("failed to clean up container", metadata: ["error": "\(error)"])
            }
            await setState(.stopped)
        }
    }

    private static func configureContainer(
        czConfig: inout LinuxContainer.Configuration,
        config: ContainerConfiguration,
        dynamicEnv: [String: String] = [:],
        log: Logger? = nil,
    ) throws {
        czConfig.cpus = config.resources.cpus
        czConfig.memoryInBytes = config.resources.memoryInBytes
        // Overcommit memory and allow more memory mappings than the kernel default
        // so workloads inside swap-less guest VMs hit limits less easily.
        var sysctls = config.sysctls
        sysctls["vm.overcommit_memory"] = "1"
        sysctls["vm.max_map_count"] = "262144"
        czConfig.sysctl = sysctls
        // If the host doesn't support this, we'll throw on container creation.
        czConfig.virtualization = config.virtualization
        czConfig.useInit = config.useInit

        // nil leaves LinuxContainer's own default set in place.
        if let maskedPaths = config.maskedPaths {
            czConfig.maskedPaths = maskedPaths
        }
        if let readonlyPaths = config.readonlyPaths {
            czConfig.readonlyPaths = readonlyPaths
        }

        if let shmSize = config.shmSize {
            for i in czConfig.mounts.indices {
                if czConfig.mounts[i].destination == "/dev/shm" {
                    czConfig.mounts[i].options.removeAll { $0.hasPrefix("size=") }
                    czConfig.mounts[i].options.append("size=\(shmSize)")
                }
            }
        }

        // R2: unrestricted host devices → guest.
        // Char: virtiofs file mount (FileMount bind preserves host rdev → guest device node).
        // Block: virtio-blk. USB mass-storage-shaped block images (.img/.raw/.iso) also get a
        // VZ USB controller attachment when the VMM is Virtualization.framework.
        for device in config.devices {
            var st = stat()
            guard lstat(device.hostPath, &st) == 0 else {
                throw ContainerizationError(
                    .invalidArgument, message: "device host path '\(device.hostPath)' does not exist")
            }
            let kind = st.st_mode & S_IFMT
            let major = Int(st.st_rdev >> 24) & 0xff  // informational; FileMount carries rdev
            let minor = Int(st.st_rdev) & 0xffffff
            log?.info(
                "R2 device map",
                metadata: [
                    "host": "\(device.hostPath)",
                    "guest": "\(device.containerPath)",
                    "major": "\(major)",
                    "minor": "\(minor)",
                ]
            )
            let readOnly: Bool = {
                guard let mode = device.mode?.lowercased() else { return false }
                return mode == "r" || mode == "ro" || mode == "rx"
            }()
            if kind == S_IFBLK {
                czConfig.mounts.append(
                    .block(
                        format: "raw",
                        source: device.hostPath,
                        destination: device.containerPath,
                        options: readOnly ? ["ro"] : []
                    )
                )
                // USB mass-storage-shaped disk images (.img/.raw/.iso) are noted for VZ USB attach.
                let lower = device.hostPath.lowercased()
                if lower.hasSuffix(".img") || lower.hasSuffix(".raw") || lower.hasSuffix(".iso") {
                    log?.info(
                        "R2 USB mass-storage candidate",
                        metadata: ["host": "\(device.hostPath)", "guest": "\(device.containerPath)"]
                    )
                }
            } else if kind == S_IFCHR {
                // Guest mknod via OCI linux.devices. Prefer Linux-standard majors for
                // well-known nodes (macOS rdev ≠ Linux); otherwise use host rdev.
                let (devType, maj, min): (String, Int64, Int64) = {
                    switch device.hostPath {
                    case "/dev/null": return ("c", 1, 3)
                    case "/dev/zero": return ("c", 1, 5)
                    case "/dev/urandom": return ("c", 1, 9)
                    case "/dev/random": return ("c", 1, 8)
                    case "/dev/tty": return ("c", 5, 0)
                    case "/dev/console": return ("c", 5, 1)
                    case "/dev/full": return ("c", 1, 7)
                    default:
                        return ("c", Int64(major), Int64(minor))
                    }
                }()
                #if CONTAINER_VMM_CR
                // OCI linux.devices on the container config is a fork-only field.
                czConfig.devices.append(
                    LinuxDevice(
                        path: device.containerPath,
                        type: devType,
                        major: maj,
                        minor: min,
                        fileMode: 0o666,
                        uid: 0,
                        gid: 0
                    )
                )
                #else
                _ = (devType, maj, min)
                #endif
                // Default vmexec path ignores OCI devices; virtiofs file mount still surfaces the node.
                czConfig.mounts.append(
                    .share(
                        source: device.hostPath,
                        destination: device.containerPath,
                        options: readOnly ? ["ro"] : []
                    )
                )
            } else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "device host path '\(device.hostPath)' must be a character or block device"
                )
            }
        }

        for mount in config.mounts {
            if try mount.isSocket() {
                let attrs = try? FileManager.default.attributesOfItem(atPath: mount.source)
                let permissions = (attrs?[.posixPermissions] as? NSNumber)
                    .map { FilePermissions(rawValue: mode_t($0.intValue)) }
                let socket = UnixSocketConfiguration(
                    source: URL(filePath: mount.source),
                    destination: URL(filePath: mount.destination),
                    permissions: permissions,
                    direction: .into,
                )
                czConfig.sockets.append(socket)
            } else {
                czConfig.mounts.append(mount.asMount)
            }
        }

        for publishedSocket in config.publishedSockets {
            // UnixSocketConfiguration (Containerization) takes URL; convert from FilePath at the boundary.
            let socketConfig = UnixSocketConfiguration(
                source: URL(filePath: publishedSocket.containerPath.string),
                destination: URL(filePath: publishedSocket.hostPath.string),
                permissions: publishedSocket.permissions,
                direction: .outOf
            )
            czConfig.sockets.append(socketConfig)
        }

        if let socketUrl = Self.sshAuthSocketHostUrl(config: config, dynamicEnv: dynamicEnv, log: log) {
            let socketPath = socketUrl.path(percentEncoded: false)
            let attrs = try? FileManager.default.attributesOfItem(atPath: socketPath)
            let permissions = (attrs?[.posixPermissions] as? NSNumber)
                .map { FilePermissions(rawValue: mode_t($0.intValue)) }
            let socketConfig = UnixSocketConfiguration(
                source: socketUrl,
                destination: URL(fileURLWithPath: Self.sshAuthSocketGuestPath),
                permissions: permissions,
                direction: .into,
            )
            czConfig.sockets.append(socketConfig)
        }

        // Prefer explicit UTS hostname (--hostname / Compose hostname). Network
        // attachment hostnames stay tied to --name for peer DNS / hosts injection.
        let hostnameSource =
            config.hostname
            ?? config.networks.first?.options.hostname
            ?? config.id
        let shortHostname =
            hostnameSource.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map { String($0) } ?? config.id
        czConfig.hostname = shortHostname

        // Docker `--domainname` / Compose `domainname:`: Containerization does not
        // expose OCI Spec.domainname yet, and `kernel.domainname` sysctl is not
        // reliably applied. Wire the practical surface: resolv.conf domain +
        // FQDN on the hosts entry for this container.
        let domainname = config.domainname?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedDomain = (domainname?.isEmpty == false) ? domainname : nil

        if let dns = config.dns {
            czConfig.dns = DNS(
                nameservers: dns.nameservers,
                domain: dns.domain ?? resolvedDomain,
                searchDomains: dns.searchDomains.isEmpty && resolvedDomain != nil
                    ? [resolvedDomain!] : dns.searchDomains,
                options: dns.options)
        } else if let resolvedDomain {
            czConfig.dns = DNS(
                nameservers: ContainerConfiguration.DNSConfiguration.defaultNameservers,
                domain: resolvedDomain,
                searchDomains: [resolvedDomain]
            )
        }

        try Self.configureInitialProcess(czConfig: &czConfig, config: config)
    }

    /// Guest path for the mounted hosts-dns helper directory.
    private static let hostsDNSGuestDir = "/run/container-helpers"
    private static let hostsDNSGuestBinary = "/run/container-helpers/hosts-dns"

    /// Locate the static Linux `hosts-dns` helper shipped next to the runtime plugin.
    private static func hostsDNSHelperDirectory() -> URL? {
        if let env = Foundation.ProcessInfo.processInfo.environment["CONTAINER_HOSTS_DNS_DIR"] {
            let url = URL(fileURLWithPath: env, isDirectory: true)
            let binary = url.appendingPathComponent("hosts-dns")
            if FileManager.default.isExecutableFile(atPath: binary.path) {
                return url
            }
        }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        // .../libexec/container/plugins/container-runtime-linux/bin/<exe>
        // → .../libexec/container/helpers
        let candidates = [
            exe.deletingLastPathComponent()  // bin
                .deletingLastPathComponent()  // container-runtime-linux
                .deletingLastPathComponent()  // plugins
                .deletingLastPathComponent()  // container
                .appendingPathComponent("helpers", isDirectory: true),
            // Dev tree: repo/resources/network-dns next to a checked-out binary.
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("resources/network-dns", isDirectory: true),
        ]
        for dir in candidates {
            let binary = dir.appendingPathComponent("hosts-dns")
            if FileManager.default.isExecutableFile(atPath: binary.path) {
                return dir
            }
        }
        return nil
    }

    /// Mount hosts-dns, wrap the init process, and prefer 127.0.0.1 as the guest resolver.
    private static func installHostsDNSIfAvailable(
        czConfig: inout LinuxContainer.Configuration,
        config: ContainerConfiguration,
        log: Logger?
    ) {
        guard config.dns != nil else { return }
        guard let helperDir = Self.hostsDNSHelperDirectory() else {
            log?.debug("hosts-dns helper not found; relying on /etc/hosts injection only")
            return
        }
        let forward =
            czConfig.dns?.nameservers.first
            ?? config.dns?.nameservers.first
            ?? "1.1.1.1"

        czConfig.mounts.append(
            Filesystem.virtiofs(
                source: helperDir.path,
                destination: Self.hostsDNSGuestDir,
                options: ["ro"]
            ).asMount
        )

        let userArgs = czConfig.process.arguments
        guard let executable = userArgs.first else { return }
        var wrapped = [
            Self.hostsDNSGuestBinary,
            "--hosts", "/etc/hosts",
            "--listen", "127.0.0.1",
            "--forward", forward,
            "--",
            executable,
        ]
        wrapped.append(contentsOf: userArgs.dropFirst())
        czConfig.process.arguments = wrapped

        let domainFromConfig: String? = {
            guard let raw = config.domainname?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                return nil
            }
            return raw
        }()
        if let dns = config.dns {
            let domain = dns.domain ?? domainFromConfig
            let search =
                dns.searchDomains.isEmpty && domain != nil
                ? [domain!] : dns.searchDomains
            czConfig.dns = DNS(
                nameservers: ["127.0.0.1"],
                domain: domain,
                searchDomains: search,
                options: dns.options
            )
        } else if let domainFromConfig {
            czConfig.dns = DNS(
                nameservers: ["127.0.0.1"],
                domain: domainFromConfig,
                searchDomains: [domainFromConfig]
            )
        } else {
            czConfig.dns = DNS(nameservers: ["127.0.0.1"])
        }
        log?.info(
            "installed in-guest hosts-dns helper",
            metadata: [
                "forward": "\(forward)",
                "helper": "\(helperDir.path)",
            ]
        )
    }

    private nonisolated func getDefaultNameservers(from attachments: [Attachment]) -> [String] {
        var nameservers: [String] = []
        var seen = Set<String>()
        for attachment in attachments {
            let gateway = attachment.ipv4Gateway.description
            if seen.insert(gateway).inserted {
                nameservers.append(gateway)
            }
        }
        return nameservers
    }

    private static func configureInitialProcess(
        czConfig: inout LinuxContainer.Configuration,
        config: ContainerConfiguration,
    ) throws {
        let process = config.initProcess

        czConfig.process.arguments = [process.executable] + process.arguments
        czConfig.process.environmentVariables = process.environment

        if config.ssh {
            if !czConfig.process.environmentVariables.contains(where: { $0.starts(with: "\(Self.sshAuthSocketEnvVar)=") }) {
                czConfig.process.environmentVariables.append("\(Self.sshAuthSocketEnvVar)=\(Self.sshAuthSocketGuestPath)")
            }
        }

        czConfig.process.terminal = process.terminal
        czConfig.process.workingDirectory = process.workingDirectory
        try czConfig.process.rlimits = process.rlimits.map {
            LinuxRLimit(
                kind: try LinuxRLimit.Kind($0.limit),
                hard: $0.hard,
                soft: $0.soft
            )
        }
        czConfig.process.capabilities = try Self.effectiveCapabilities(
            capAdd: config.capAdd,
            capDrop: config.capDrop
        )
        switch process.user {
        case .raw(let name):
            czConfig.process.user = .init(
                uid: 0,
                gid: 0,
                umask: nil,
                additionalGids: process.supplementalGroups,
                username: name
            )
        case .id(let uid, let gid):
            czConfig.process.user = .init(
                uid: uid,
                gid: gid,
                umask: nil,
                additionalGids: process.supplementalGroups,
                username: ""
            )
        }
    }

    private nonisolated func configureProcessConfig(config: ProcessConfiguration, stdio: [FileHandle?], containerConfig: ContainerConfiguration)
        throws -> LinuxProcessConfiguration
    {
        var proc = LinuxProcessConfiguration()
        proc.stdin = stdio[0]
        proc.stdout = stdio[1]
        proc.stderr = stdio[2]

        proc.arguments = [config.executable] + config.arguments
        proc.environmentVariables = config.environment

        if containerConfig.ssh {
            if !proc.environmentVariables.contains(where: { $0.starts(with: "\(Self.sshAuthSocketEnvVar)=") }) {
                proc.environmentVariables.append("\(Self.sshAuthSocketEnvVar)=\(Self.sshAuthSocketGuestPath)")
            }
        }

        proc.terminal = config.terminal
        proc.workingDirectory = config.workingDirectory
        try proc.rlimits = config.rlimits.map {
            LinuxRLimit(
                kind: try LinuxRLimit.Kind($0.limit),
                hard: $0.hard,
                soft: $0.soft
            )
        }
        proc.capabilities = try Self.effectiveCapabilities(
            capAdd: containerConfig.capAdd,
            capDrop: containerConfig.capDrop
        )
        switch config.user {
        case .raw(let name):
            proc.user = .init(
                uid: 0,
                gid: 0,
                umask: nil,
                additionalGids: config.supplementalGroups,
                username: name
            )
        case .id(let uid, let gid):
            proc.user = .init(
                uid: uid,
                gid: gid,
                umask: nil,
                additionalGids: config.supplementalGroups,
                username: ""
            )
        }

        return proc
    }

    /// Compute effective Linux capabilities from the OCI default set, capAdd, and capDrop.
    /// Steps are processed in order, so later steps override earlier ones:
    /// 1. If "ALL" in capDrop, start empty; otherwise start from OCI defaults.
    /// 2. If "ALL" in capAdd, replace with all caps (overriding step 1); otherwise add individual caps.
    /// 3. Remove individual capDrop entries (skipping "ALL" sentinel).
    private static func effectiveCapabilities(capAdd: [String], capDrop: [String]) throws -> Containerization.LinuxCapabilities {
        // Step 1: Determine base set
        var caps: Set<CapabilityName>
        if capDrop.contains("ALL") {
            caps = []
        } else {
            caps = Set(Containerization.LinuxCapabilities.defaultOCICapabilities.effective)
        }

        // Step 2: Process adds
        if capAdd.contains("ALL") {
            caps = Set(CapabilityName.allCases)
        } else {
            for name in capAdd {
                caps.insert(try CapabilityName(rawValue: name))
            }
        }

        // Step 3: Remove individual drops (skip "ALL" sentinel)
        for name in capDrop where name != "ALL" {
            caps.remove(try CapabilityName(rawValue: name))
        }

        return Containerization.LinuxCapabilities(capabilities: Array(caps))
    }

    private nonisolated func closeHandle(_ handle: Int32) throws {
        guard close(handle) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func getContainer() throws -> ContainerInfo {
        guard let container else {
            throw ContainerizationError(
                .invalidState,
                message: "no container found"
            )
        }
        return container
    }

    /// CR must not call `LinuxContainer.stop()` — that path dials the guest agent
    /// (`withAgent` → kill/umount) before `vm.stop()`, and a wedged vsock dial parks
    /// delete forever. Tear down HVF via the VM instance only.
    private func stopCRVirtualMachine(_ lc: LinuxContainer) async throws {
        try await lc.withVirtualMachineInstance { vm in
            try await vm.stop()
        }
    }

    private static func isCRBackend() -> Bool {
        #if CONTAINER_VMM_CR
        let backend = Self.resolveVMMBackend()
        return backend == "cr" || backend == "crvirtualization" || backend == "cleanroom"
        #else
        return false
        #endif
    }

    /// SIGKILL out-of-process CRGuestHelper children. Safe to call without locks;
    /// unblocks stop when actor/AsyncLock paths are wedged on vsock dial.
    private static func killCRGuestHelperChildren() {
        #if os(macOS)
        let myPid = getpid()
        var buffer = [pid_t](repeating: 0, count: 256)
        let nbytes = proc_listchildpids(myPid, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.stride))
        guard nbytes > 0 else { return }
        let n = Int(nbytes) / MemoryLayout<pid_t>.stride
        for i in 0..<n {
            let pid = buffer[i]
            guard pid > 1 else { continue }
            var path = [CChar](repeating: 0, count: 4 * 1024)
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            let s = String(decoding: path.map { UInt8(bitPattern: $0) }.prefix { $0 != 0 }, as: UTF8.self)
            if s.contains("CRGuestHelper") {
                _ = Darwin.kill(pid, SIGKILL)
            }
        }
        #endif
    }

    private func gracefulStopContainer(_ lc: LinuxContainer, signal: Signal, timeout: Duration) async throws -> ExitStatus {
        if Self.isCRBackend() {
            // Cooperative STOP via helper (flushes blk, Darwin.exit) under a hard
            // budget, then SIGKILL survivors. Never call LinuxContainer.stop()
            // (agent dial) or NIO ELG close on borrowed vsock FDs.
            self.log.info("CR backend: cooperative helper STOP then SIGKILL survivors")
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try await self.stopCRVirtualMachine(lc)
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(1))
                    }
                    _ = try await group.next()
                    group.cancelAll()
                }
            } catch {
                self.log.error(
                    "CR cooperative stop failed; falling back to SIGKILL",
                    metadata: ["error": "\(error)"]
                )
            }
            Self.killCRGuestHelperChildren()
            try? await Task.sleep(for: .milliseconds(100))
            Self.killCRGuestHelperChildren()
            return ExitStatus(exitCode: 137)
        }

        // VZ path: try graceful shut down, then always power off the vm.
        var code = ExitStatus(exitCode: 255)
        do {
            code = try await withThrowingTaskGroup(of: ExitStatus.self) { group in
                group.addTask {
                    try await lc.wait()
                }
                group.addTask {
                    try await lc.kill(signal)
                    try await Task.sleep(for: timeout)
                    try await lc.kill(.kill)

                    return ExitStatus(exitCode: 137)
                }
                guard let code = try await group.next() else {
                    throw ContainerizationError(
                        .internalError,
                        message: "failed to get exit code from gracefully stopping container"
                    )
                }
                group.cancelAll()

                return code
            }
        } catch {
            self.log.error("graceful stop failed; forcing vm shutdown", metadata: ["error": "\(error)"])
        }

        // Now actually bring down the vm.
        try await lc.stop()

        return code
    }

    private func cleanUpContainer(containerInfo: ContainerInfo, exitStatus: ExitStatus? = nil) async throws {
        let container = containerInfo.container
        let id = container.id

        do {
            if Self.isCRBackend() {
                // Helper already SIGKILL'd in gracefulStop; do not re-enter VM stop
                // (can hang on AsyncLock / NIO). Just ensure children are dead.
                Self.killCRGuestHelperChildren()
            } else {
                try await container.stop()
            }
        } catch {
            self.log.error("failed to stop container during cleanup", metadata: ["error": "\(error)"])
        }

        await self.stopSocketForwarders()

        for session in networkSessions { session.close() }
        networkSessions = []

        // Always close bootstrap stdio writers (including on create failure) so the
        // container log FD is not leaked for the life of the runtime process.
        try? containerInfo.io.out?.close()
        try? containerInfo.io.err?.close()
        try? containerInfo.io.in?.close()

        let status = exitStatus ?? ExitStatus(exitCode: 255)
        self.releaseWaiters(for: id, status: status)
    }

    /// Select CRVirtualization (default, F6) or VZ via `CONTAINER_VMM_BACKEND=vz|cr`.
    private static func makeVirtualMachineManager(
        kernel: Kernel,
        initialFilesystem: Containerization.Mount,
        rosetta: Bool,
        logger: Logger
    ) -> any VirtualMachineManager {
        let backend = Self.resolveVMMBackend()
        switch backend {
        case "vz", "virtualization", "apple":
            logger.info("using VZVirtualMachineManager (CONTAINER_VMM_BACKEND=\(backend))")
            return VZVirtualMachineManager(
                kernel: kernel,
                initialFilesystem: initialFilesystem,
                rosetta: rosetta,
                logger: logger
            )
        case "cr", "crvirtualization", "cleanroom":
            #if CONTAINER_VMM_CR
            logger.info("using CRVirtualMachineManager (CONTAINER_VMM_BACKEND=\(backend))")
            return CRVirtualMachineManager(
                kernel: kernel,
                initialFilesystem: initialFilesystem,
                rosetta: rosetta,
                logger: logger
            )
            #else
            logger.warning(
                "CONTAINER_VMM_BACKEND=\(backend) requested but runtime was not built with CONTAINER_VMM_CR; falling back to VZ"
            )
            return VZVirtualMachineManager(
                kernel: kernel,
                initialFilesystem: initialFilesystem,
                rosetta: rosetta,
                logger: logger
            )
            #endif
        default:
            #if CONTAINER_VMM_CR
            logger.info("using CRVirtualMachineManager (default backend=\(backend))")
            return CRVirtualMachineManager(
                kernel: kernel,
                initialFilesystem: initialFilesystem,
                rosetta: rosetta,
                logger: logger
            )
            #else
            logger.warning(
                "default VMM backend '\(backend)' but runtime was not built with CONTAINER_VMM_CR; using VZ"
            )
            return VZVirtualMachineManager(
                kernel: kernel,
                initialFilesystem: initialFilesystem,
                rosetta: rosetta,
                logger: logger
            )
            #endif
        }
    }

    /// F6: default is `cr`. Override with `CONTAINER_VMM_BACKEND=vz`, else sidecar
    /// file `vmm-backend` next to the runtime binary (install writes `cr`).
    private static func resolveVMMBackend() -> String {
        if let env = Foundation.ProcessInfo.processInfo.environment["CONTAINER_VMM_BACKEND"],
            !env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return env.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0])
        let sidecar = exe.deletingLastPathComponent().appendingPathComponent("vmm-backend")
        if let raw = try? String(contentsOf: sidecar, encoding: .utf8) {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !value.isEmpty { return value }
        }
        return "cr"
    }
}

extension XPCMessage {
    fileprivate func signal() throws -> String {
        guard let signal = self.string(key: RuntimeKeys.signal.rawValue) else {
            throw ContainerizationError(.invalidArgument, message: "missing signal in xpc message")
        }
        return signal
    }

    fileprivate func stopOptions() throws -> ContainerStopOptions {
        guard let data = self.dataNoCopy(key: RuntimeKeys.stopOptions.rawValue) else {
            throw ContainerizationError(.invalidArgument, message: "empty StopOptions")
        }
        return try JSONDecoder().decode(ContainerStopOptions.self, from: data)
    }

    fileprivate func setState(_ state: SandboxSnapshot) throws {
        let data = try JSONEncoder().encode(state)
        self.set(key: RuntimeKeys.snapshot.rawValue, value: data)
    }

    fileprivate func stdio() -> [FileHandle?] {
        var handles = [FileHandle?](repeating: nil, count: 3)
        if let stdin = self.fileHandle(key: RuntimeKeys.stdin.rawValue) {
            handles[0] = stdin
        }
        if let stdout = self.fileHandle(key: RuntimeKeys.stdout.rawValue) {
            handles[1] = stdout
        }
        if let stderr = self.fileHandle(key: RuntimeKeys.stderr.rawValue) {
            handles[2] = stderr
        }
        return handles
    }

    fileprivate func setFileHandle(_ handle: FileHandle) {
        self.set(key: RuntimeKeys.fd.rawValue, value: handle)
    }

    fileprivate func processConfig() throws -> ProcessConfiguration {
        guard let data = self.dataNoCopy(key: RuntimeKeys.processConfig.rawValue) else {
            throw ContainerizationError(.invalidArgument, message: "empty process configuration")
        }
        return try JSONDecoder().decode(ProcessConfiguration.self, from: data)
    }

    fileprivate func dynamicEnv() throws -> [String: String] {
        let data = self.dataNoCopy(key: RuntimeKeys.dynamicEnv.rawValue)
        let dynamicEnv = try data.map { try JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        return dynamicEnv
    }

}

extension ContainerResource.Bundle {
    func createLogFile() throws {
        // Intentionally create-or-truncate: restarted containers must not append to a
        // stale log (O_TRUNC also force-updates kernel state that otherwise delayed writes).
        // Writers open this path separately after create.
        let fd = Darwin.open(self.containerLog.path, O_CREAT | O_WRONLY | O_TRUNC, 0o644)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        close(fd)
    }
}

extension RuntimeService {
    /// Annotate mount failures with actionable install / model-limit hints.
    fileprivate static func annotateMountErrors(_ error: Error, mounts: [Filesystem]) -> Error {
        if let nfs = annotateNFSKernelError(error, mounts: mounts) {
            return nfs
        }
        if let shared = annotateSharedVolumeError(error, mounts: mounts) {
            return shared
        }
        return error
    }

    /// When guest NFS mounts fail because the kernel lacks NFS, surface an actionable install hint.
    fileprivate static func annotateNFSKernelError(_ error: Error, mounts: [Filesystem]) -> Error? {
        let hasNFS = mounts.contains { $0.type == .nfs }
        guard hasNFS else { return nil }
        let text = "\(error)".lowercased()
        let looksLikeMissingFS =
            text.contains("enodev")
            || text.contains("no such device")
            || text.contains("unknown filesystem type")
            || text.contains("filesystem type nfs")
            || text.contains("wrong fs type")
            || (text.contains("nfs") && (text.contains("invalid argument") || text.contains("einval")))
        guard looksLikeMissingFS else { return nil }
        return ContainerizationError(
            .invalidArgument,
            message:
                "NFS mount failed: guest kernel lacks NFS client support (\(error)). "
                + "Preferred path: `container system kernel set --recommended` "
                + "(CONTAINER_PREFERRED_KERNEL=nfs, default) or `make install-recommended-kernel` / "
                + "`make install-nfs-kernel`. CONTAINER_PREFERRED_KERNEL=kata uses the historic Kata "
                + "tarball (often omits nfs). Or set `--binary path/to/vmlinux-arm64 --force`. "
                + "See docs/volumes.md#nfs-mounts."
        )
    }

    /// Block-image named volumes remain single-writer. Directory (virtiofs) volumes share.
    fileprivate static func annotateSharedVolumeError(_ error: Error, mounts: [Filesystem]) -> Error? {
        let blockNamed = mounts.filter { $0.isVolume && !$0.options.readonly && $0.isBlock }
        guard !blockNamed.isEmpty else { return nil }
        let text = "\(error)".lowercased()
        let looksLikeAttach =
            text.contains("invalid storage")
            || text.contains("storage attachment")
            || text.contains("vzerror")
            || text.contains("already attached")
            || (text.contains("volume") && text.contains("attach"))
        guard looksLikeAttach else { return nil }
        let names = blockNamed.compactMap(\.volumeName)
        let listed = names.isEmpty ? "a block named volume" : names.joined(separator: ", ")
        return ContainerizationError(
            .invalidArgument,
            message:
                "named volume attach failed (\(error)): block-image volume \(listed) is exclusive "
                + "virtio-blk (single-writer per VM). Recreate with the default directory/virtiofs "
                + "plane for multi-writer sharing, or use separate volumes / NFS / one writer. "
                + "See docs/volumes.md."
        )
    }
}

extension Filesystem {
    var asMount: Containerization.Mount {
        switch self.type {
        case .tmpfs:
            return .any(
                type: "tmpfs",
                source: self.source,
                destination: self.destination,
                options: self.options
            )
        case .nfs:
            // Guest NFS client: mount(2) type "nfs".
            // Docker shape is `--mount type=nfs,source=<export>,addr=<server>,…`.
            // Linux expects the mount source as `server:/export` (and usually `nolock`
            // when rpc.statd is not running in the guest).
            var source = self.source
            var options = self.options
            let addr = options.first(where: { $0.hasPrefix("addr=") })
                .map { String($0.dropFirst("addr=".count)) }
            if let addr, !addr.isEmpty, !source.contains(":") {
                source = "\(addr):\(source)"
            }
            // Prefer kernel `vers=` spelling; accept Docker `nfsvers=` as an alias.
            options = options.map { opt in
                if opt.hasPrefix("nfsvers=") {
                    return "vers=" + opt.dropFirst("nfsvers=".count)
                }
                return opt
            }
            if !options.contains(where: { $0 == "nolock" || $0 == "lock" || $0.hasPrefix("lock=") }) {
                options.append("nolock")
            }
            return .any(
                type: "nfs",
                source: source,
                destination: self.destination,
                options: options
            )
        case .virtiofs:
            return .share(
                source: self.source,
                destination: self.destination,
                options: self.options
            )
        case .block(let format, let cacheMode, let syncMode):
            return .block(
                format: format,
                source: self.source,
                destination: self.destination,
                options: self.options,
                runtimeOptions: [
                    "\(Filesystem.CacheMode.vzRuntimeOptionKey)=\(cacheMode.asVZRuntimeOption)",
                    "\(Filesystem.SyncMode.vzRuntimeOptionKey)=\(syncMode.asVZRuntimeOption)",
                ],
            )
        case .volume(_, let format, let cacheMode, let syncMode):
            // Directory / virtiofs-format named volumes share a host directory via
            // virtiofs (multi-writer). Block-image volumes stay exclusive virtio-blk.
            if self.isSharedVirtiofsVolume {
                return .share(
                    source: self.source,
                    destination: self.destination,
                    options: self.options
                )
            }
            return .block(
                format: format,
                source: self.source,
                destination: self.destination,
                options: self.options,
                runtimeOptions: [
                    "\(Filesystem.CacheMode.vzRuntimeOptionKey)=\(cacheMode.asVZRuntimeOption)",
                    "\(Filesystem.SyncMode.vzRuntimeOptionKey)=\(syncMode.asVZRuntimeOption)",
                ],
            )
        }
    }

    func isSocket() throws -> Bool {
        if !self.isVirtiofs {
            return false
        }
        let info = try File.info(self.source)
        return info.isSocket
    }
}

extension Filesystem.CacheMode {
    static let vzRuntimeOptionKey = "vzDiskImageCachingMode"

    var asVZRuntimeOption: String {
        switch self {
        case .on: "cached"
        case .off: "uncached"
        case .auto: "automatic"
        }
    }
}

extension Filesystem.SyncMode {
    static let vzRuntimeOptionKey = "vzDiskImageSynchronizationMode"

    var asVZRuntimeOption: String {
        switch self {
        case .full: "full"
        case .fsync: "fsync"
        case .nosync: "none"
        }
    }
}

struct MultiWriter: Writer {
    let handles: [FileHandle]

    init(handles: [FileHandle]) {
        self.handles = handles
    }

    func close() throws {
        var firstError: Error?
        for handle in handles {
            do {
                try handle.close()
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    func write(_ data: Data) throws {
        var firstError: Error?
        for handle in handles {
            do {
                try handle.write(contentsOf: data)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }
}

extension FileHandle: @retroactive ReaderStream, @retroactive Writer {
    public func write(_ data: Data) throws {
        try self.write(contentsOf: data)
    }

    public func stream() -> AsyncStream<Data> {
        .init { cont in
            self.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    self.readabilityHandler = nil
                    cont.finish()
                    return
                }
                cont.yield(data)
            }
        }
    }
}

// MARK: State handler and bundle creation helpers

extension RuntimeService {
    private func initializeWaiters(for id: String) throws {
        guard waiters[id] == nil else {
            throw ContainerizationError(.invalidState, message: "waiter for \(id) already initialized")
        }
        waiters[id] = ExitWaiter()
    }

    private func waitForExit(id: String, cont: CheckedContinuation<ExitStatus, Never>) {
        if let status = exitStatuses[id] {
            cont.resume(returning: status)
            return
        }
        if let waiter = waiters[id] {
            waiter.wait(cont)
            return
        }
        // Late wait: register a waiter, then re-check exitStatuses in case release
        // landed between the first lookup and this insert.
        let waiter = ExitWaiter()
        waiters[id] = waiter
        if let status = exitStatuses[id] {
            waiter.doExit(exitStatus: status)
        }
        waiter.wait(cont)
    }

    private func releaseWaiters(for id: String, status: ExitStatus) {
        exitStatuses[id] = status
        if let waiter = waiters.removeValue(forKey: id) {
            waiter.doExit(exitStatus: status)
        }
    }

    private func takeProcess(_ id: String) -> LinuxProcess? {
        self.processes.removeValue(forKey: id)?.process
    }

    private func dropProcessClosingIO(_ id: String) {
        if let orphan = self.processes.removeValue(forKey: id) {
            for handle in orphan.io { try? handle?.close() }
        }
    }

    private func setUnderlyingProcess(_ id: String, _ process: LinuxProcess) throws {
        guard var info = self.processes[id] else {
            throw ContainerizationError(.invalidState, message: "process \(id) not found")
        }
        info.process = process
        self.processes[id] = info
    }

    private func setProcessState(id: String, state: State) throws {
        guard var info = self.processes[id] else {
            throw ContainerizationError(.invalidState, message: "process \(id) not found")
        }
        info.state = state
        self.processes[id] = info
    }

    private func setContainer(_ info: ContainerInfo) {
        self.container = info
    }

    private func setNetworkSessions(_ sessions: [XPCClientSession]) {
        self.networkSessions = sessions
    }

    private func appendNetworkSession(_ session: XPCClientSession) {
        self.networkSessions.append(session)
    }

    private func addNewProcess(_ id: String, _ config: ProcessConfiguration, _ io: [FileHandle?]) throws {
        guard self.processes[id] == nil else {
            throw ContainerizationError(.invalidArgument, message: "process \(id) already exists")
        }
        self.processes[id] = ProcessInfo(config: config, process: nil, state: .created, io: io)
    }

    private struct ProcessInfo {
        let config: ProcessConfiguration
        var process: LinuxProcess?
        var state: State
        let io: [FileHandle?]
    }

    private struct ContainerInfo {
        let container: LinuxContainer
        let config: ContainerConfiguration
        var attachments: [Attachment]
        let bundle: ContainerResource.Bundle
        let io: (in: FileHandle?, out: MultiWriter?, err: MultiWriter?)
    }

    /// States the underlying sandbox can be in.
    public enum State: Sendable, Equatable {
        /// Sandbox is created. This should be what the service starts the sandbox in.
        case created
        /// Bootstrap will transition a .created state to .booted.
        case booted
        /// startProcess on the init process will transition .booted to .running.
        case running
        /// pause() transitions .running to .paused (VM suspended).
        case paused
        /// At the beginning of stop() .running will be transitioned to .stopping.
        case stopping
        /// Once a stop is successful, .stopping will transition to .stopped.
        case stopped
        /// .shuttingDown will be the last state the runtime service will ever be in. Shortly
        /// afterwards the process will exit.
        case shuttingDown
    }

    func setState(_ new: State) {
        self.state = new
    }

    /// Check if a bundle exists at the given path
    private func bundleExists(at path: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: path.path) else {
            return false
        }

        let bundle = ContainerResource.Bundle(path: path)
        do {
            _ = try bundle.configuration
            _ = try bundle.kernel
            return true
        } catch {
            return false
        }
    }

    /// Create bundle from RuntimeConfiguration
    private func createBundle() throws {
        do {
            let runtimeConfig = try RuntimeConfiguration.readRuntimeConfiguration(from: self.root)
            // Always materialize under self.root — runtimeConfig.path can deserialize to a
            // different absolute URL after XPC/JSON round-trip and leave kernel.json missing.
            _ = try ContainerResource.Bundle.create(
                path: self.root,
                initialFilesystem: runtimeConfig.initialFilesystem,
                kernel: runtimeConfig.kernel,
                containerConfiguration: runtimeConfig.containerConfiguration,
                containerRootFilesystem: runtimeConfig.containerRootFilesystem,
                options: runtimeConfig.options
            )
            self.log.info("created bundle", metadata: ["configPath": "\(self.root.path)"])
        } catch {
            self.log.error("failed to create bundle", metadata: ["error": "\(error)"])
            throw error
        }
    }
}
