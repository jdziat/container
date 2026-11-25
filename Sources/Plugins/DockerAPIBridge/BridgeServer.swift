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

import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import Darwin
import Foundation
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix

/// Curated Docker Engine API subset over a Unix socket (Packet 6 plugin path).
struct DockerAPIBridgeServer: Sendable {
    static let defaultSocketPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Application Support/com.apple.container/docker-api-bridge.sock")
            .path
    }()

    static let supportMatrix = """
        Supported (curated subset; not the full Engine API):
          GET  /_ping
          GET  /version
          GET  /info
          GET  /containers/json
          POST /containers/create          (see HostConfig below)
          GET  /containers/{id}/json
          GET  /containers/{id}/logs       (container stdio only; multiplexed for non-TTY, raw for TTY; tail=; no follow/since)
          GET  /containers/{id}/changes
          GET  /containers/{id}/stats      (one-shot JSON subset; no stream)
          GET  /containers/{id}/top        (guest ps Titles/Processes subset)
          POST /containers/{id}/start
          POST /containers/{id}/stop
          POST /containers/{id}/restart
          POST /containers/{id}/kill
          POST /containers/{id}/wait
          POST /containers/{id}/pause
          POST /containers/{id}/unpause
          POST /containers/{id}/rename     (query name=)
          POST /containers/{id}/exec       (ExecCreate subset)
          POST /containers/prune           (stopped containers; filters label=)
          DELETE /containers/{id}
          POST /exec/{id}/start            (streams stdout/stderr as Docker multiplexed frames, raw for TTY; no stdin/hijack)
          GET  /exec/{id}/json
          GET  /images/json
          POST /images/create              (pull; fromImage query)
          POST /images/{name}/tag          (repo=, tag= query)
          DELETE /images/{name}
          POST /build                      (curated: tar context + t= tag; streams JSON lines)
          GET  /events                     (live events from now, or since= unix seconds)
          GET  /networks
          GET  /networks/{id}
          POST /networks/create
          POST /networks/prune             (filters label=)
          DELETE /networks/{id}
          GET  /volumes
          GET  /volumes/{name}
          POST /volumes/create
          POST /volumes/prune              (REQUIRES filters label=; unscoped volume prune is refused)
          DELETE /volumes/{name}

        POST /containers/create HostConfig:
          Honored:   Memory, NanoCpus, PortBindings, Binds, RestartPolicy, AutoRemove, NetworkMode
                     (a named network; aliases via NetworkingConfig), Dns/DnsSearch/DnsOptions, ExtraHosts,
                     Sysctls, CapAdd/CapDrop, Devices, Tmpfs, ShmSize, Init, ReadonlyRootfs.
          Accepted, no effect (reported in the create response Warnings): Privileged.
          Any other NON-DEFAULT HostConfig value is rejected with HTTP 400 naming the key; it is never
          silently ignored. Docker's zero values (and -1 for MemorySwappiness/PidsLimit) are accepted.

        Prune safety: `filters` supports only `label`. An unknown filter key, or a malformed/empty
        `label`, is a 400, never an unscoped prune. Unfiltered containers/networks prune removes
        everything unused (Docker's semantics).

        Not supported (HTTP 501): images/{name}/push, containers/{id}/archive, containers/{id}/attach,
        containers/{id}/update, system/df, Swarm (/swarm, /services, ...), and any route not listed above.
        Unsupported routes return HTTP 501 with a stable JSON error body.
        This printed matrix is the complete Engine bridge contract; extend the
        plugin to widen it. Prefer the `container` CLI / `bin/docker` shim for
        everyday workflows.
        API version prefixes (/v1.41/...) are accepted and stripped.
        Optional --socket /var/run/docker.sock requires permission to bind that path
        (typically root or an appropriately privileged user); the socket is mode 0600.
        """

    let socketPath: String
    let log: Logger
    private let execSessions: ExecSessionStore

    init(socketPath: String, log: Logger) {
        self.socketPath = socketPath
        self.log = log
        self.execSessions = ExecSessionStore()
    }

    func run() async throws {
        let dir = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let server = try await Self.bind(socketPath: socketPath)
        try await withThrowingDiscardingTaskGroup { group in
            try await server.executeThenClose { connections in
                for try await connection in connections {
                    group.addTask {
                        await self.serve(connection)
                    }
                }
            }
        }
    }

    private static func bind(socketPath: String) async throws -> NIOAsyncChannel<
        NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>, Never
    > {
        // Keep a restrictive umask through bind+chmod so a failed chmod cannot leave the
        // socket at a wider creation mode for even a short window.
        let previousUmask = umask(0o177)
        do {
            let server = try await ServerBootstrap(group: NIOSingletons.posixEventLoopGroup)
                .bind(unixDomainSocketPath: socketPath, cleanupExistingSocketFile: true) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                        return try NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>(
                            wrappingChannelSynchronously: channel
                        )
                    }
                }
            guard chmod(socketPath, 0o600) == 0 else {
                throw ContainerizationError(
                    .internalError, message: "chmod \(socketPath): \(String(cString: strerror(errno)))")
            }
            umask(previousUmask)
            return server
        } catch {
            umask(previousUmask)
            throw error
        }
    }

    private func serve(
        _ connection: NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>
    ) async {
        do {
            try await connection.executeThenClose { inbound, outbound in
                var head: HTTPRequestHead?
                var body = ByteBuffer()
                for try await part in inbound {
                    switch part {
                    case .head(let requestHead):
                        head = requestHead
                        body.clear()
                    case .body(var buf):
                        body.writeBuffer(&buf)
                    case .end:
                        if let head {
                            try await self.respond(to: head, body: body, outbound: outbound)
                        }
                        head = nil
                        body.clear()
                    }
                }
            }
        } catch {
            log.debug("connection closed", metadata: ["error": "\(error)"])
        }
    }

    private func respond(
        to request: HTTPRequestHead,
        body: ByteBuffer,
        outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>
    ) async throws {
        let path = Self.stripAPIVersion(Self.path(from: request.uri))
        let query = Self.queryItems(from: request.uri)
        let method = request.method
        log.debug("request", metadata: ["method": "\(method)", "path": "\(path)"])

        do {
            switch (method, path) {
            case (.GET, "/_ping"), (.HEAD, "/_ping"):
                try await writeText("OK", status: .ok, outbound: outbound, headOnly: method == .HEAD)
            case (.GET, "/version"):
                try await writeJSONObject(Self.versionPayload(), outbound: outbound)
            case (.GET, "/info"):
                try await writeJSONObject(Self.infoPayload(), outbound: outbound)
            case (.GET, "/containers/json"):
                try await handleContainersList(outbound: outbound)
            case (.POST, "/containers/create"):
                try await handleContainerCreate(query: query, body: body, outbound: outbound)
            case (.GET, let p) where p.hasPrefix("/containers/") && p.hasSuffix("/json"):
                guard let id = containerID(from: p, suffix: "/json") else {
                    try await writeUnsupported(method: method, path: path, outbound: outbound)
                    break
                }
                try await handleContainerInspect(id: id, outbound: outbound)
            case (.GET, let p) where p.hasPrefix("/containers/") && p.hasSuffix("/logs"):
                guard let id = containerID(from: p, suffix: "/logs") else {
                    try await writeUnsupported(method: method, path: path, outbound: outbound)
                    break
                }
                try await handleContainerLogs(id: id, query: query, outbound: outbound)
            case (.GET, let p) where p.hasPrefix("/containers/") && p.hasSuffix("/changes"):
                guard let id = containerID(from: p, suffix: "/changes") else {
                    try await writeUnsupported(method: method, path: path, outbound: outbound)
                    break
                }
                try await handleContainerChanges(id: id, outbound: outbound)
            case (.GET, let p) where p.hasPrefix("/containers/") && p.hasSuffix("/stats"):
                guard let id = containerID(from: p, suffix: "/stats") else {
                    try await writeUnsupported(method: method, path: path, outbound: outbound)
                    break
                }
                try await handleContainerStats(id: id, outbound: outbound)
            case (.GET, let p) where p.hasPrefix("/containers/") && p.hasSuffix("/top"):
                guard let id = containerID(from: p, suffix: "/top") else {
                    try await writeUnsupported(method: method, path: path, outbound: outbound)
                    break
                }
                try await handleContainerTop(id: id, query: query, outbound: outbound)
            case (.POST, let p) where p.hasPrefix("/containers/") && p.hasSuffix("/start"):
                guard let id = containerID(from: p, suffix: "/start") else {
                    try await writeUnsupported(method: method, path: path, outbound: outbound)
                    break
                }
                try await handleContainerStart(id: id, outbound: outbound)
            case (.POST, let p) where p.hasPrefix("/containers/") && p.hasSuffix("/stop"):
                guard let id = containerID(from: p, suffix: "/stop") else {
                    try await writeUnsupported(method: method, path: path, outbound: outbound)
                    break
                }
                try await handleContainerStop(id: id, outbound: outbound)
            case (.POST, let p) where p.hasPrefix("/containers/") && p.hasSuffix("/kill"):
                guard let id = containerID(from: p, suffix: "/kill") else {
                    try await writeUnsupported(method: method, path: path, outbound: outbound)
                    break
                }
                try await handleContainerKill(id: id, outbound: outbound)
            case (.POST, let p) where p.hasPrefix("/containers/") && p.hasSuffix("/wait"):
                guard let id = containerID(from: p, suffix: "/wait") else {
                    try await writeUnsupported(method: method, path: path, outbound: outbound)
                    break
                }
                try await handleContainerWait(id: id, outbound: outbound)
            case (.POST, let p) where p.hasPrefix("/containers/") && p.hasSuffix("/pause"):
                guard let id = containerID(from: p, suffix: "/pause") else {
                    try await writeUnsupported(method: method, path: path, outbound: outbound)
                    break
                }
                try await handleContainerPause(id: id, outbound: outbound)
            case (.POST, let p) where p.hasPrefix("/containers/") && p.hasSuffix("/unpause"):
                guard let id = containerID(from: p, suffix: "/unpause") else {
                    try await writeUnsupported(method: method, path: path, outbound: outbound)
                    break
                }
                try await handleContainerUnpause(id: id, outbound: outbound)
            case (.POST, let p) where p.hasPrefix("/containers/") && p.hasSuffix("/rename"):
                guard let id = containerID(from: p, suffix: "/rename") else {
                    try await writeUnsupported(method: method, path: path, outbound: outbound)
                    break
                }
                guard let newName = query.first(where: { $0.name == "name" })?.value, !newName.isEmpty else {
                    throw BridgeHTTPError(status: .badRequest, message: "name query parameter is required")
                }
                try await handleContainerRename(id: id, newName: newName, outbound: outbound)
            case (.POST, let p) where p.hasPrefix("/containers/") && p.hasSuffix("/exec"):
                guard let id = containerID(from: p, suffix: "/exec") else {
                    try await writeUnsupported(method: method, path: path, outbound: outbound)
                    break
                }
                try await handleExecCreate(containerId: id, body: body, outbound: outbound)
            case (.DELETE, let p) where Self.isExactContainerResourcePath(p):
                // Exact `/containers/{id}` only — any extra path segment is a subresource (501).
                let id = String(p.dropFirst("/containers/".count))
                // Curated bridge defaults force=true (historical behavior). Pass force=0 for 409.
                let force = Self.queryBool(query, name: "force", default: true)
                try await handleContainerDelete(id: id, force: force, outbound: outbound)
            case (.POST, let p) where p.hasPrefix("/exec/") && p.hasSuffix("/start"):
                guard let id = execID(from: p, suffix: "/start") else {
                    try await writeUnsupported(method: method, path: path, outbound: outbound)
                    break
                }
                try await handleExecStart(execId: id, body: body, outbound: outbound)
            case (.GET, let p) where p.hasPrefix("/exec/") && p.hasSuffix("/json"):
                guard let id = execID(from: p, suffix: "/json") else {
                    try await writeUnsupported(method: method, path: path, outbound: outbound)
                    break
                }
                try await handleExecInspect(execId: id, outbound: outbound)
            case (.GET, "/images/json"):
                try await handleImagesList(outbound: outbound)
            case (.POST, "/images/create"):
                try await handleImageCreate(query: query, outbound: outbound)
            case (.DELETE, let p) where p.hasPrefix("/images/"):
                let name = String(p.dropFirst("/images/".count))
                guard !name.isEmpty else {
                    try await writeUnsupported(method: method, path: path, outbound: outbound)
                    break
                }
                let force = Self.queryBool(query, name: "force", default: false)
                try await handleImageDelete(name: name, force: force, outbound: outbound)
            case (.POST, "/build"):
                try await handleBuild(query: query, body: body, outbound: outbound)
            case (.GET, "/events"):
                try await handleEvents(query: query, outbound: outbound)
            case (.GET, "/networks"):
                try await handleNetworksList(outbound: outbound)
            case (.POST, "/networks/create"):
                try await handleNetworkCreate(body: body, outbound: outbound)
            case (.GET, let p) where p.hasPrefix("/networks/") && !p.contains("/containers/"):
                let id = String(p.dropFirst("/networks/".count))
                guard Self.isSafeContainerID(id) else {
                    try await writeUnsupported(method: method, path: path, outbound: outbound)
                    break
                }
                try await handleNetworkInspect(id: id, outbound: outbound)
            case (.DELETE, let p) where p.hasPrefix("/networks/"):
                let id = String(p.dropFirst("/networks/".count))
                guard Self.isSafeContainerID(id) else {
                    try await writeUnsupported(method: method, path: path, outbound: outbound)
                    break
                }
                try await handleNetworkDelete(id: id, outbound: outbound)
            case (.GET, "/volumes"):
                try await handleVolumesList(outbound: outbound)
            case (.POST, "/volumes/create"):
                try await handleVolumeCreate(body: body, outbound: outbound)
            case (.GET, let p) where p.hasPrefix("/volumes/"):
                let name = String(p.dropFirst("/volumes/".count))
                guard Self.isSafeContainerID(name) else {
                    try await writeUnsupported(method: method, path: path, outbound: outbound)
                    break
                }
                try await handleVolumeInspect(name: name, outbound: outbound)
            case (.DELETE, let p) where p.hasPrefix("/volumes/"):
                let name = String(p.dropFirst("/volumes/".count))
                guard Self.isSafeContainerID(name) else {
                    try await writeUnsupported(method: method, path: path, outbound: outbound)
                    break
                }
                try await handleVolumeDelete(name: name, outbound: outbound)
            case (.POST, let p) where p.hasPrefix("/containers/") && p.hasSuffix("/restart"):
                guard let id = containerID(from: p, suffix: "/restart") else {
                    try await writeUnsupported(method: method, path: path, outbound: outbound)
                    break
                }
                try await handleContainerRestart(id: id, outbound: outbound)
            case (.POST, "/containers/prune"):
                try await handleContainersPrune(query: query, outbound: outbound)
            case (.POST, "/networks/prune"):
                try await handleNetworksPrune(query: query, outbound: outbound)
            case (.POST, "/volumes/prune"):
                try await handleVolumesPrune(query: query, outbound: outbound)
            case (.POST, let p) where p.hasPrefix("/images/") && p.hasSuffix("/tag"):
                let name = String(p.dropFirst("/images/".count).dropLast("/tag".count))
                guard !name.isEmpty else {
                    try await writeUnsupported(method: method, path: path, outbound: outbound)
                    break
                }
                try await handleImageTag(name: name, query: query, outbound: outbound)
            default:
                try await writeUnsupported(method: method, path: path, outbound: outbound)
            }
        } catch let error as BridgeHTTPError {
            try await writeJSONObject(
                ["message": error.message],
                status: error.status,
                outbound: outbound
            )
        } catch let error as ContainerizationError where error.code == .exists {
            // Docker Engine returns 409 Conflict for name collisions on create.
            try await writeJSONObject(
                ["message": error.message],
                status: .conflict,
                outbound: outbound
            )
        } catch {
            try await writeJSONObject(
                ["message": "\(error)"],
                status: .internalServerError,
                outbound: outbound
            )
        }
    }

    // MARK: - Handlers

    private func handleContainersList(outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>) async throws {
        let client = ContainerClient()
        let containers = try await client.list()
        let payload: [[String: Any]] = containers.map { snap in
            let displayName = Self.displayName(for: snap)
            return [
                "Id": snap.configuration.id,
                "Names": ["/\(displayName)"],
                "Image": snap.configuration.image.reference,
                "ImageID": snap.configuration.image.digest,
                "State": snap.status.rawValue,
                "Status": snap.status.rawValue,
                "Labels": snap.configuration.labels,
                "Ports": publishedPorts(snap),
            ]
        }
        try await writeJSONObject(payload, outbound: outbound)
    }

    private func requireContainer(_ id: String, client: ContainerClient) async throws -> ContainerSnapshot {
        do {
            return try await client.get(id: id)
        } catch let error as ContainerizationError where error.code == .notFound {
            throw BridgeHTTPError(status: .notFound, message: "No such container: \(id)")
        } catch {
            throw BridgeHTTPError(status: .internalServerError, message: "\(error)")
        }
    }

    private func handleContainerInspect(id: String, outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>) async throws {
        let client = ContainerClient()
        let snap = try await requireContainer(id, client: client)
        let health: [String: Any]? = {
            guard snap.configuration.healthcheck != nil else { return nil }
            return [
                "Status": snap.configuration.healthStatus.rawValue
            ]
        }()
        // Pid is unavailable over this curated bridge. ExitCode is not persisted on the
        // snapshot; report 0 here and use /containers/{id}/wait for the real code.
        var state: [String: Any] = [
            "Status": snap.status.rawValue,
            "Running": snap.status == .running,
            "Pid": 0,
            "ExitCode": 0,
        ]
        if let health { state["Health"] = health }
        let displayName = Self.displayName(for: snap)
        let guestHostname =
            snap.configuration.hostname
            ?? snap.configuration.networks.first?.options.hostname
            ?? snap.networks.first?.hostname
            ?? displayName
        let shortHostname =
            guestHostname.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? guestHostname
        let payload: [String: Any] = [
            "Id": snap.configuration.id,
            "Name": "/\(displayName)",
            "Created": ISO8601DateFormatter().string(from: snap.configuration.creationDate),
            "Path": snap.configuration.initProcess.executable,
            "Args": snap.configuration.initProcess.arguments,
            "State": state,
            "Image": snap.configuration.image.digest,
            "Config": [
                "Hostname": shortHostname,
                "Env": snap.configuration.initProcess.environment,
                "Cmd": [snap.configuration.initProcess.executable] + snap.configuration.initProcess.arguments,
                "Image": snap.configuration.image.reference,
                "Labels": snap.configuration.labels,
                "WorkingDir": snap.configuration.initProcess.workingDirectory,
            ],
            "NetworkSettings": [
                "Ports": dockerPorts(snap),
                "Networks": dockerNetworks(snap),
            ],
            "HostConfig": [
                "RestartPolicy": [
                    "Name": snap.configuration.restartPolicy.rawValue,
                    "MaximumRetryCount": snap.configuration.restartMaxRetries ?? 0,
                ],
                "PublishAllPorts": false,
            ],
        ]
        try await writeJSONObject(payload, outbound: outbound)
    }

    private func handleContainerLogs(
        id: String, query: [URLQueryItem], outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>
    ) async throws {
        let client = ContainerClient()
        let snapshot = try await client.get(id: id)
        let handles = try await client.logs(id: id)
        // Handle 0 is the container's stdio log; handle 1 is the VM boot log. Docker's /logs is
        // the former only: the boot log is kernel noise that must never reach an app's log reader.
        var data = Data()
        if let stdio = handles.first, let chunk = try stdio.readToEnd() {
            data = chunk
        }
        if let raw = query.first(where: { $0.name == "tail" })?.value, let count = Int(raw), count >= 0 {
            data = Self.lastLines(of: data, count: count)
        }
        // Docker frames non-TTY logs as a multiplexed stream and sends TTY logs raw.
        let tty = snapshot.configuration.initProcess.terminal
        if tty {
            try await writeData(data, contentType: "application/vnd.docker.raw-stream", outbound: outbound)
        } else {
            let framed = data.isEmpty ? Data() : Self.muxFrame(stream: 1, payload: data)
            try await writeData(framed, contentType: "application/vnd.docker.multiplexed-stream", outbound: outbound)
        }
    }

    /// The last `count` newline-terminated lines of `data` (`count == 0` yields nothing).
    static func lastLines(of data: Data, count: Int) -> Data {
        guard count > 0 else { return Data() }
        var newlines = 0
        var index = data.endIndex
        // Skip a single trailing newline so it does not count as an empty final line.
        if data.last == UInt8(ascii: "\n") { index = data.index(before: index) }
        while index > data.startIndex {
            index = data.index(before: index)
            if data[index] == UInt8(ascii: "\n") {
                newlines += 1
                if newlines == count { return data[data.index(after: index)...] }
            }
        }
        return data
    }

    private func handleEvents(query: [URLQueryItem], outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>) async throws {
        // Docker streams new events from "now" unless `since` (unix seconds) is given. The bus
        // replays its whole buffer, so filter by timestamp to get the same semantics.
        let sinceNano: Int64 = {
            if let raw = query.first(where: { $0.name == "since" })?.value, let seconds = Double(raw) {
                return Int64(seconds * 1_000_000_000)
            }
            return Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        }()
        // Chunked JSON lines compatible with Docker's /events stream.
        // Head is committed before the poll loop; on failure close the chunked
        // body cleanly instead of rethrowing (which would write a second head).
        try await outbound.write(
            .head(
                .init(
                    version: .http1_1,
                    status: .ok,
                    headers: [
                        "Content-Type": "application/json",
                        "Transfer-Encoding": "chunked",
                        "Connection": "keep-alive",
                    ]
                )))
        do {
            let client = ContainerClient()
            var since: UInt64 = 0
            while !Task.isCancelled {
                let batch = try await client.events(since: since, timeout: .seconds(30))
                for event in batch {
                    since = max(since, event.id)
                    if event.timeNano < sinceNano { continue }
                    let payload: [String: Any] = [
                        "status": event.status,
                        "id": event.actorID,
                        "Type": event.type,
                        "Action": event.action,
                        "Actor": [
                            "ID": event.actorID,
                            "Attributes": event.actorAttributes,
                        ],
                        "time": event.time,
                        "timeNano": event.timeNano,
                    ]
                    let data = try JSONSerialization.data(withJSONObject: payload)
                    var line = data
                    line.append(contentsOf: "\n".utf8)
                    // NIO's HTTPResponseEncoder chunk-encodes for us (Transfer-Encoding: chunked);
                    // hand-framing here would double-encode. A write failure (client
                    // disconnect) ends the stream.
                    try await outbound.write(.body(.byteBuffer(ByteBuffer(bytes: line))))
                }
            }
        } catch {
            log.debug("events stream ending", metadata: ["error": "\(error)"])
        }
        // NIO writes the terminating chunk itself; writing "0\r\n\r\n" here would put junk in the body.
        try? await outbound.write(.end(nil))
    }

    private func handleContainerStart(id: String, outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>) async throws {
        let client = ContainerClient()
        let snap = try await client.get(id: id)
        if snap.status == .running {
            try await writeEmpty(status: .notModified, outbound: outbound)
            return
        }
        // Clients address containers by name or ID; the runtime calls below key on the ID.
        _ = try await client.bootstrap(id: snap.id, stdio: [nil, nil, nil])
        let process = client.initProcess(id: snap.id)
        try await process.start()
        try await writeEmpty(status: .noContent, outbound: outbound)
    }

    private func handleContainerStop(id: String, outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>) async throws {
        let client = ContainerClient()
        try await client.stop(id: id)
        try await writeEmpty(status: .noContent, outbound: outbound)
    }

    private func handleContainerKill(id: String, outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>) async throws {
        let client = ContainerClient()
        try await client.initProcess(id: id).kill(SIGKILL)
        try await writeEmpty(status: .noContent, outbound: outbound)
    }

    private func handleContainerWait(id: String, outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>) async throws {
        let client = ContainerClient()
        let code = try await client.initProcess(id: id).wait()
        try await writeJSONObject(["StatusCode": code], outbound: outbound)
    }

    private func handleContainerDelete(
        id: String, force: Bool, outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>
    ) async throws {
        let client = ContainerClient()
        do {
            try await client.delete(id: id, force: force)
        } catch let error as ContainerizationError where !force {
            // Map any refusal to delete a running container to Docker's 409.
            if error.code == .invalidState || error.code == .invalidArgument {
                throw BridgeHTTPError(
                    status: .conflict,
                    message: "cannot remove a running container \(id); use force=1")
            }
            throw error
        }
        try await writeEmpty(status: .noContent, outbound: outbound)
    }

    private func handleContainerPause(id: String, outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>)
        async throws
    {
        let client = ContainerClient()
        do {
            try await client.pause(id: id)
        } catch let error as ContainerizationError {
            throw Self.mapPauseUnpauseError(error, id: id, action: "pause")
        }
        try await writeEmpty(status: .noContent, outbound: outbound)
    }

    private func handleContainerUnpause(id: String, outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>)
        async throws
    {
        let client = ContainerClient()
        do {
            try await client.unpause(id: id)
        } catch let error as ContainerizationError {
            throw Self.mapPauseUnpauseError(error, id: id, action: "unpause")
        }
        try await writeEmpty(status: .noContent, outbound: outbound)
    }

    private static func mapPauseUnpauseError(
        _ error: ContainerizationError, id: String, action: String
    ) -> BridgeHTTPError {
        switch error.code {
        case .notFound:
            return BridgeHTTPError(status: .notFound, message: "No such container: \(id)")
        case .invalidState, .invalidArgument:
            return BridgeHTTPError(
                status: .conflict,
                message: "cannot \(action) container \(id): \(error.message)"
            )
        default:
            return BridgeHTTPError(status: .internalServerError, message: "\(error)")
        }
    }

    private func handleContainerChanges(id: String, outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>)
        async throws
    {
        let client = ContainerClient()
        let changes: [ContainerDiffChange]
        do {
            changes = try await client.diff(id: id)
        } catch let error as ContainerizationError where error.code == .notFound {
            throw BridgeHTTPError(status: .notFound, message: "No such container: \(id)")
        }
        // Docker /changes: Kind 0=modified, 1=added, 2=deleted.
        let payload: [[String: Any]] = changes.map { change in
            let kind: Int
            switch change.kind {
            case .changed: kind = 0
            case .added: kind = 1
            case .deleted: kind = 2
            }
            return ["Path": change.path, "Kind": kind]
        }
        try await writeJSONObject(payload, outbound: outbound)
    }

    /// One-shot Docker-shaped stats JSON. Streaming (`stream=1`) is not offered.
    private func handleContainerStats(id: String, outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>)
        async throws
    {
        let client = ContainerClient()
        let snap: ContainerSnapshot
        do {
            snap = try await client.get(id: id)
        } catch let error as ContainerizationError where error.code == .notFound {
            throw BridgeHTTPError(status: .notFound, message: "No such container: \(id)")
        } catch {
            throw BridgeHTTPError(status: .internalServerError, message: "\(error)")
        }
        let stats: ContainerStats
        do {
            stats = try await client.stats(id: id)
        } catch let error as ContainerizationError where error.code == .notFound {
            throw BridgeHTTPError(status: .notFound, message: "No such container: \(id)")
        } catch {
            throw BridgeHTTPError(status: .internalServerError, message: "\(error)")
        }
        let read = ISO8601DateFormatter().string(from: Date())
        let name = Self.displayName(for: snap)
        let payload: [String: Any] = [
            "read": read,
            "preread": read,
            "id": snap.configuration.id,
            "name": "/\(name)",
            "cpu_stats": [
                "cpu_usage": [
                    "total_usage": stats.cpuUsageUsec ?? 0,
                    "percpu_usage": [] as [UInt64],
                    "usage_in_kernelmode": 0,
                    "usage_in_usermode": 0,
                ],
                "system_cpu_usage": 0,
                "online_cpus": 1,
                "throttling_data": [
                    "periods": 0,
                    "throttled_periods": 0,
                    "throttled_time": 0,
                ],
            ] as [String: Any],
            "precpu_stats": [
                "cpu_usage": [
                    "total_usage": 0,
                    "percpu_usage": [] as [UInt64],
                    "usage_in_kernelmode": 0,
                    "usage_in_usermode": 0,
                ],
                "system_cpu_usage": 0,
                "online_cpus": 1,
            ] as [String: Any],
            "memory_stats": [
                "usage": stats.memoryUsageBytes ?? 0,
                "max_usage": stats.memoryUsageBytes ?? 0,
                "limit": stats.memoryLimitBytes ?? 0,
            ] as [String: Any],
            "networks": [
                "eth0": [
                    "rx_bytes": stats.networkRxBytes ?? 0,
                    "tx_bytes": stats.networkTxBytes ?? 0,
                    "rx_packets": 0,
                    "tx_packets": 0,
                    "rx_errors": 0,
                    "tx_errors": 0,
                    "rx_dropped": 0,
                    "tx_dropped": 0,
                ]
            ] as [String: Any],
            "blkio_stats": [
                "io_service_bytes_recursive": [
                    ["major": 0, "minor": 0, "op": "Read", "value": stats.blockReadBytes ?? 0],
                    ["major": 0, "minor": 0, "op": "Write", "value": stats.blockWriteBytes ?? 0],
                ]
            ] as [String: Any],
            "pids_stats": [
                "current": stats.numProcesses ?? 0,
                "limit": 0,
            ] as [String: Any],
        ]
        try await writeJSONObject(payload, outbound: outbound)
    }

    /// Guest `ps` Titles/Processes subset (Docker Engine top shape).
    private func handleContainerTop(
        id: String,
        query: [URLQueryItem],
        outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>
    ) async throws {
        let client = ContainerClient()
        let snap = try await requireContainer(id, client: client)
        guard snap.status == .running else {
            throw BridgeHTTPError(
                status: .conflict,
                message: "Container \(id) is not running")
        }
        let psArgsRaw = query.first(where: { $0.name == "ps_args" })?.value ?? "-ef"
        let psArgs = psArgsRaw.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { !$0.isEmpty }
        let (code, output) = try await Self.execCapture(
            client: client,
            containerId: snap.configuration.id,
            executable: "ps",
            arguments: psArgs.isEmpty ? ["-ef"] : psArgs
        )
        guard code == 0 else {
            throw BridgeHTTPError(
                status: .internalServerError,
                message: "ps failed in container \(id): \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let lines = output.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        guard let header = lines.first else {
            try await writeJSONObject(["Titles": [] as [String], "Processes": [] as [[String]]], outbound: outbound)
            return
        }
        let titles = header.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let processes: [[String]] = lines.dropFirst().map { line in
            // Split on whitespace; keep remainder of command in the last column when present.
            var cols = line.split(
                maxSplits: max(titles.count - 1, 0),
                omittingEmptySubsequences: true,
                whereSeparator: { $0.isWhitespace }
            ).map(String.init)
            while cols.count < titles.count { cols.append("") }
            return cols
        }
        try await writeJSONObject(["Titles": titles, "Processes": processes], outbound: outbound)
    }

    private func handleContainerRename(
        id: String, newName: String, outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>
    ) async throws {
        let client = ContainerClient()
        do {
            try await client.rename(id: id, newName: newName)
        } catch let error as ContainerizationError {
            switch error.code {
            case .notFound:
                throw BridgeHTTPError(status: .notFound, message: "No such container: \(id)")
            case .exists:
                throw BridgeHTTPError(
                    status: .conflict, message: "Conflict. The name \"\(newName)\" is already in use")
            case .invalidArgument:
                throw BridgeHTTPError(status: .badRequest, message: error.message)
            default:
                // Prefer structured codes on nested causes over string matching.
                if let nested = error.cause as? ContainerizationError {
                    switch nested.code {
                    case .notFound:
                        throw BridgeHTTPError(status: .notFound, message: "No such container: \(id)")
                    case .exists:
                        throw BridgeHTTPError(
                            status: .conflict, message: "Conflict. The name \"\(newName)\" is already in use")
                    case .invalidArgument:
                        throw BridgeHTTPError(status: .badRequest, message: nested.message)
                    default:
                        break
                    }
                }
                throw BridgeHTTPError(status: .internalServerError, message: "\(error)")
            }
        }
        try await writeEmpty(status: .noContent, outbound: outbound)
    }

    /// Capture stdout/stderr from a one-shot guest process (top / diagnostics).
    private static func execCapture(
        client: ContainerClient,
        containerId: String,
        executable: String,
        arguments: [String]
    ) async throws -> (code: Int32, output: String) {
        let pipe = Pipe()
        // True once the success path has closed the write end and handed the
        // read end to drainTask. Until then, defer must close both ends if
        // createProcess/start throws.
        var drainOwnsPipe = false
        defer {
            if !drainOwnsPipe {
                try? pipe.fileHandleForWriting.close()
                try? pipe.fileHandleForReading.close()
            }
        }
        let config = ProcessConfiguration(
            executable: executable, arguments: arguments, environment: [], terminal: false)
        let proc = try await client.createProcess(
            containerId: containerId,
            processId: UUID().uuidString.lowercased(),
            configuration: config,
            stdio: [nil, pipe.fileHandleForWriting, pipe.fileHandleForWriting]
        )
        try await proc.start()
        pipe.fileHandleForWriting.closeFile()
        drainOwnsPipe = true
        // Drain on a background queue while wait() runs so a full pipe cannot
        // deadlock the guest, and so we do not block the cooperative pool.
        let drainTask = Task<Data, Never> {
            await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .utility).async {
                    let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
                    try? pipe.fileHandleForReading.close()
                    cont.resume(returning: bytes)
                }
            }
        }
        let code = try await proc.wait()
        let data = await drainTask.value
        return (code, String(data: data, encoding: .utf8) ?? "")
    }

    private func handleContainerCreate(
        query: [URLQueryItem],
        body: ByteBuffer,
        outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>
    ) async throws {
        let json = try Self.jsonObject(from: body)
        guard let imageRef = json["Image"] as? String, !imageRef.isEmpty else {
            throw BridgeHTTPError(status: .badRequest, message: "Image is required")
        }

        let queryName = query.first(where: { $0.name == "name" })?.value
        let hostname = json["Hostname"] as? String
        // Docker: Name comes from the `name` query param only; Hostname is guest config.
        let identity = Utility.createContainerIdentity(name: queryName)
        guard ManagedContainer.nameValid(identity.name) else {
            throw BridgeHTTPError(
                status: .badRequest, message: "container name \(identity.name) is not a valid container name")
        }

        let hostConfig = json["HostConfig"] as? [String: Any] ?? [:]
        let systemConfig = try await ClientHealthCheck.loadContainerSystemConfig()
        let platform = Platform.current

        let img: ClientImage
        do {
            img = try await ClientImage.fetch(
                reference: imageRef,
                platform: platform,
                containerSystemConfig: systemConfig
            )
            _ = try await img.getCreateSnapshot(platform: platform)
        } catch let error as ContainerizationError where error.code == .notFound {
            throw BridgeHTTPError(status: .notFound, message: "No such image: \(imageRef)")
        }

        let imageConfig = try await img.config(for: platform).config
        let process = try Self.processConfiguration(from: json, imageConfig: imageConfig)

        var config = ContainerConfiguration(
            id: identity.id,
            image: img.description,
            process: process,
            name: identity.name
        )
        config.platform = platform
        config.labels = (json["Labels"] as? [String: String]) ?? [:]
        config.resources = Self.resources(from: hostConfig, defaults: systemConfig.container)
        config.publishedPorts = try Self.portBindings(from: hostConfig["PortBindings"])
        config.mounts = try Self.binds(from: hostConfig["Binds"])
        if let restart = try Self.restartPolicy(from: hostConfig["RestartPolicy"]) {
            config.restartPolicy = restart.policy
            config.restartMaxRetries = restart.policy == .onFailure ? restart.maximumRetryCount : nil
        }

        if let hostname, !hostname.isEmpty {
            config.hostname = hostname
        }
        // Network DNS name follows Docker Name; UTS hostname is separate (config.hostname).
        let networkHostname = identity.name
        let networkClient = NetworkClient()
        guard let builtinNetworkId = try await networkClient.builtin?.id else {
            throw BridgeHTTPError(
                status: .serviceUnavailable,
                message: "builtin network is not present; start the container system and retry"
            )
        }
        config.networks = [
            AttachmentConfiguration(
                network: builtinNetworkId,
                options: AttachmentOptions(hostname: networkHostname, macAddress: nil, mtu: 1280)
            )
        ]
        let dnsDefaults = systemConfig.container.dns
        config.dns = ContainerConfiguration.DNSConfiguration(
            nameservers: dnsDefaults?.nameservers ?? ContainerConfiguration.DNSConfiguration.defaultNameservers,
            domain: dnsDefaults?.domain ?? systemConfig.dns.domain,
            searchDomains: dnsDefaults?.searchDomains ?? [],
            options: dnsDefaults?.options ?? []
        )

        let createWarnings = try await Self.applyHostConfig(
            hostConfig, networking: json["NetworkingConfig"] as? [String: Any], to: &config,
            networkHostname: networkHostname)

        let autoRemove = (hostConfig["AutoRemove"] as? Bool) ?? false
        let options = ContainerCreateOptions(autoRemove: autoRemove)
        let kernel = try await ClientKernel.getDefaultKernel(for: .current)
        let client = ContainerClient()
        try await client.create(configuration: config, options: options, kernel: kernel, initImage: nil)
        try await writeJSONObject(["Id": identity.id, "Warnings": createWarnings], status: .created, outbound: outbound)
    }

    private func handleExecCreate(
        containerId: String,
        body: ByteBuffer,
        outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>
    ) async throws {
        let client = ContainerClient()
        let snap = try await requireContainer(containerId, client: client)
        let json = try Self.jsonObject(from: body)
        guard let cmd = json["Cmd"] as? [String], let executable = cmd.first, !executable.isEmpty else {
            throw BridgeHTTPError(status: .badRequest, message: "Cmd is required")
        }
        var process = snap.configuration.initProcess
        process.executable = executable
        process.arguments = Array(cmd.dropFirst())
        process.terminal = (json["Tty"] as? Bool) ?? false
        if let env = json["Env"] as? [String], !env.isEmpty {
            // Merge/override on top of the container environment (keep PATH, etc.).
            // Last-wins for duplicate keys (Docker permits duplicates in Env arrays).
            var merged: [String: String] = [:]
            for entry in process.environment {
                guard let eq = entry.firstIndex(of: "=") else { continue }
                merged[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
            }
            for entry in env {
                guard let eq = entry.firstIndex(of: "=") else { continue }
                merged[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
            }
            process.environment = merged.map { "\($0.key)=\($0.value)" }.sorted()
        }
        if let cwd = json["WorkingDir"] as? String, !cwd.isEmpty {
            process.workingDirectory = cwd
        }
        if let user = json["User"] as? String, !user.isEmpty {
            process.user = .raw(userString: user)
        }
        switch await execSessions.create(containerId: snap.configuration.id, process: process) {
        case .capacityExceeded:
            throw BridgeHTTPError(
                status: .serviceUnavailable,
                message: "too many exec sessions; retry after existing execs finish"
            )
        case .created(let execId):
            try await writeJSONObject(["Id": execId], status: .created, outbound: outbound)
        }
    }

    private func handleExecStart(
        execId: String,
        body: ByteBuffer,
        outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>
    ) async throws {
        // Parse the body before claiming so a malformed request does not burn the session.
        var detach = false
        if body.readableBytes > 0 {
            let json = try Self.jsonObject(from: body)
            detach = (json["Detach"] as? Bool) ?? false
        }

        // Atomically claim the session so concurrent starts cannot both pass.
        let session: ExecSessionStore.Session
        switch await execSessions.claimStart(execId) {
        case .notFound:
            throw BridgeHTTPError(status: .notFound, message: "No such exec instance: \(execId)")
        case .alreadyStarted:
            throw BridgeHTTPError(status: .conflict, message: "exec \(execId) has already been started")
        case .claimed(let claimed):
            session = claimed
        }

        let client = ContainerClient()
        let process: ClientProcess
        let stdoutPipe: Pipe?
        let stderrPipe: Pipe?
        do {
            // Detached execs have no reader, so give them no pipes. Attached execs stream
            // stdout/stderr back to the caller (Docker's `AttachStdout`/`AttachStderr`).
            stdoutPipe = detach ? nil : Pipe()
            stderrPipe = detach || session.process.terminal ? nil : Pipe()
            process = try await client.createProcess(
                containerId: session.containerId,
                processId: execId,
                configuration: session.process,
                stdio: [nil, stdoutPipe?.fileHandleForWriting, stderrPipe?.fileHandleForWriting]
            )
        } catch {
            await execSessions.resetClaim(execId)
            throw error
        }
        do {
            try await process.start()
        } catch {
            // createProcess may have registered a guest process; clear it and
            // unclaim so a retry is not stuck on alreadyStarted.
            try? await process.kill(SIGKILL)
            await execSessions.resetClaim(execId)
            throw error
        }

        if detach {
            let store = execSessions
            Task {
                let code = (try? await process.wait()) ?? 125
                await store.markFinished(execId, exitCode: code)
            }
            try await writeEmpty(status: .ok, outbound: outbound)
            return
        }

        // Record the exit code as soon as the process ends. This starts BEFORE any response write:
        // if a write throws (client already gone) the session must still leave "running", or it
        // is never evicted and leaks a slot. Always markFinished so a wait() failure cannot leak.
        let store = execSessions
        let waiter = Task {
            let code = (try? await process.wait()) ?? 125
            await store.markFinished(execId, exitCode: code)
        }

        // The guest holds the other pipe ends; close ours so EOF arrives when the guest side closes.
        try? stdoutPipe?.fileHandleForWriting.close()
        try? stderrPipe?.fileHandleForWriting.close()

        // Stream output in Docker's wire format: 8-byte frames `[stream, 0, 0, 0, len(be32)]` for
        // non-TTY, raw bytes for TTY. The caller reads the exit code from GET /exec/{id}/json.
        let tty = session.process.terminal
        let control = ExecStreamControl()
        do {
            try await outbound.write(
                .head(
                    HTTPResponseHead(
                        version: .http1_1, status: .ok,
                        headers: [
                            "Content-Type": tty ? "application/vnd.docker.raw-stream" : "application/vnd.docker.multiplexed-stream",
                            "Transfer-Encoding": "chunked",
                            "Server": "container-docker-api-bridge",
                        ])))

            let (frames, continuation) = AsyncStream<Data>.makeStream()
            let readers = DispatchGroup()
            for (pipe, stream) in [(stdoutPipe, UInt8(1)), (stderrPipe, UInt8(2))] {
                guard let handle = pipe?.fileHandleForReading else { continue }
                readers.enter()
                // availableData blocks; keep it off the cooperative pool.
                DispatchQueue.global().async {
                    defer { readers.leave() }
                    while !control.stopped {
                        let chunk = handle.availableData
                        if chunk.isEmpty { break }  // EOF
                        // Backpressure: at most `credits` unwritten frames are ever buffered, so a
                        // slow client (or `yes`) cannot grow the bridge's memory without bound.
                        control.credits.wait()
                        if control.stopped { break }
                        continuation.yield(tty ? chunk : Self.muxFrame(stream: stream, payload: chunk))
                    }
                }
            }
            readers.notify(queue: .global()) { continuation.finish() }

            // A background grandchild that inherited stdout would hold the response open forever;
            // bound the stream a few seconds after the process exits.
            let finisher = Task {
                _ = await waiter.value
                try? await Task.sleep(for: .seconds(3))
                continuation.finish()
            }
            defer { finisher.cancel() }

            for await frame in frames {
                try await outbound.write(.body(.byteBuffer(ByteBuffer(bytes: frame))))
                control.credits.signal()
            }

            // The stream can end (reader EOF) a moment before wait() returns. Make the exit code
            // observable before the response completes, so a client that reads /exec/{id}/json as
            // soon as the body ends never sees Running:true. Bounded: wait() can outlive the pipes.
            for _ in 0..<50 {
                if await store.get(execId)?.running == false { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            try await outbound.write(.end(nil))
        } catch {
            // Client gone or write failed: stop the readers and the guest process so nothing is
            // left blocked on a full pipe. The waiter above still records the exit.
            control.stop()
            try? await process.kill(SIGKILL)
            throw error
        }
        control.stop()
    }

    /// Cancellation + backpressure shared between an exec's reader threads and its writer.
    private final class ExecStreamControl: @unchecked Sendable {
        let credits = DispatchSemaphore(value: 64)
        private let lock = NSLock()
        private var isStopped = false
        var stopped: Bool { lock.lock(); defer { lock.unlock() }; return isStopped }
        func stop() {
            lock.lock(); isStopped = true; lock.unlock()
            for _ in 0..<64 { credits.signal() }  // release any reader parked on backpressure
        }
    }

    private func handleContainerRestart(id: String, outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>)
        async throws
    {
        let client = ContainerClient()
        // Docker clients address containers by name or ID; the runtime calls below key on the ID.
        let snapshot = try await client.get(id: id)
        let containerId = snapshot.id
        if snapshot.status == .running || snapshot.status == .paused {
            try await client.stop(id: containerId)
        }
        _ = try await client.bootstrap(id: containerId, stdio: [nil, nil, nil])
        try await client.initProcess(id: containerId).start()
        try await writeEmpty(status: .noContent, outbound: outbound)
    }

    /// Docker prune responses report what was removed. Stopped containers only; running ones are untouched.
    private func handleContainersPrune(query: [URLQueryItem], outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>) async throws {
        let scope = try Self.pruneLabelFilter(query)
        let client = ContainerClient()
        let filters = ContainerListFilters(status: .stopped).withoutPlugins([ResourcePluginValues.machine, ResourcePluginValues.cluster])
        var deleted: [String] = []
        for snapshot in try await client.list(filters: filters) where scope.matches(snapshot.configuration.labels) {
            do {
                try await client.delete(id: snapshot.id)
                deleted.append(snapshot.id)
            } catch {
                log.warning("prune skipped container", metadata: ["id": "\(snapshot.id)", "error": "\(error)"])
            }
        }
        try await writeJSONObject(["ContainersDeleted": deleted, "SpaceReclaimed": 0], outbound: outbound)
    }

    private func handleNetworksPrune(query: [URLQueryItem], outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>) async throws {
        let scope = try Self.pruneLabelFilter(query)
        let client = NetworkClient()
        let inUse = Set(try await ContainerClient().list().flatMap { $0.configuration.networks.map(\.network) })
        var deleted: [String] = []
        for network in try await client.list() where !network.isBuiltin && !inUse.contains(network.id) && scope.matches(network.labels.dictionary) {
            do {
                try await client.delete(id: network.id)
                deleted.append(network.id)
            } catch {
                log.warning("prune skipped network", metadata: ["id": "\(network.id)", "error": "\(error)"])
            }
        }
        try await writeJSONObject(["NetworksDeleted": deleted], outbound: outbound)
    }

    private func handleVolumesPrune(query: [URLQueryItem], outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>) async throws {
        let scope = try Self.pruneLabelFilter(query)
        // Docker 1.42+ removes only anonymous volumes unless all=true; this engine cannot tell them
        // apart from named ones, so an unscoped volume prune would delete named data. Require a scope.
        guard !scope.labels.isEmpty else {
            throw BridgeHTTPError(
                status: .badRequest,
                message: "volumes/prune requires filters={\"label\":[...]}: unscoped volume prune would delete named volumes")
        }
        let inUse = Set(try await ContainerClient().list().flatMap { $0.configuration.mounts.compactMap { $0.isVolume ? $0.volumeName : nil } })
        var deleted: [String] = []
        for volume in try await ClientVolume.list() where !inUse.contains(volume.name) && scope.matches(volume.labels) {
            do {
                try await ClientVolume.delete(name: volume.name)
                deleted.append(volume.name)
            } catch {
                log.warning("prune skipped volume", metadata: ["name": "\(volume.name)", "error": "\(error)"])
            }
        }
        try await writeJSONObject(["VolumesDeleted": deleted, "SpaceReclaimed": 0], outbound: outbound)
    }

    /// Docker prune `filters` (JSON in the query). Only `label` is supported. Unknown keys are a
    /// 400, never ignored: a caller that believes it scoped a prune must not get an unscoped one,
    /// because an unscoped prune removes every unused container/network/volume on the system.
    struct PruneScope {
        var labels: [(key: String, value: String?)] = []
        func matches(_ actual: [String: String]) -> Bool {
            labels.allSatisfy { required in
                guard let value = actual[required.key] else { return false }
                return required.value.map { $0 == value } ?? true
            }
        }
    }

    static func pruneLabelFilter(_ query: [URLQueryItem]) throws -> PruneScope {
        guard let raw = query.first(where: { $0.name == "filters" })?.value, !raw.isEmpty else { return PruneScope() }
        guard let data = raw.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw BridgeHTTPError(status: .badRequest, message: "filters must be a JSON object") }
        var scope = PruneScope()
        for (key, value) in object {
            guard key == "label" else {
                throw BridgeHTTPError(
                    status: .badRequest,
                    message: "prune filter '\(key)' is not supported (only 'label'); refusing to run an unscoped prune")
            }
            // Docker sends {"label":["k=v"]} or {"label":{"k=v":true}}. Anything else is rejected:
            // a value we cannot read must never degrade into "no filter", which prunes everything.
            let entries: [String]
            if let list = value as? [String] {
                entries = list
            } else if let map = value as? [String: Any] {
                entries = Array(map.keys)
            } else {
                throw BridgeHTTPError(status: .badRequest, message: "prune filter 'label' must be an array or object")
            }
            guard !entries.isEmpty else {
                throw BridgeHTTPError(status: .badRequest, message: "prune filter 'label' is empty; refusing to run an unscoped prune")
            }
            for entry in entries {
                let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                guard let key = parts.first, !key.isEmpty else {
                    throw BridgeHTTPError(status: .badRequest, message: "prune filter 'label' entry '\(entry)' has an empty key")
                }
                scope.labels.append((key, parts.count > 1 ? parts[1] : nil))
            }
        }
        return scope
    }

    /// `POST /images/{name}/tag?repo=<repo>&tag=<tag>`
    private func handleImageTag(name: String, query: [URLQueryItem], outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>)
        async throws
    {
        guard let repo = query.first(where: { $0.name == "repo" })?.value, !repo.isEmpty else {
            throw BridgeHTTPError(status: .badRequest, message: "repo query parameter is required")
        }
        let tag = query.first(where: { $0.name == "tag" })?.value
        let target = (tag?.isEmpty == false) ? "\(repo):\(tag!)" : repo
        let image: ClientImage
        do {
            image = try await ClientImage.get(
                reference: name, containerSystemConfig: try await ClientHealthCheck.loadContainerSystemConfig())
        } catch let error as ContainerizationError where error.code == .notFound {
            throw BridgeHTTPError(status: .notFound, message: "No such image: \(name)")
        }
        _ = try await image.tag(new: target)
        try await writeEmpty(status: .created, outbound: outbound)
    }

    // MARK: HostConfig mapping (honor, or reject loudly; never silently ignore)

    /// HostConfig keys handled by `/containers/create` (here or in `resources`/`binds`/...).
    static let handledHostConfigKeys: Set<String> = [
        "Memory", "NanoCpus", "PortBindings", "Binds", "RestartPolicy", "AutoRemove", "NetworkMode",
        "Dns", "DnsSearch", "DnsOptions", "ShmSize", "Init", "CapAdd", "CapDrop", "Sysctls", "ExtraHosts",
        "Devices", "Privileged", "ReadonlyRootfs", "Tmpfs",
    ]

    /// True when `value` is Docker's zero/default for `key`. Real clients send a full HostConfig
    /// of defaults on every create, so only a non-default value for an unsupported key is a problem.
    static func isDefaultHostConfigValue(key: String, value: Any) -> Bool {
        if value is NSNull { return true }
        switch key {
        case "LogConfig":
            let type = (value as? [String: Any])?["Type"] as? String
            return type == nil || ["", "json-file", "local"].contains(type!)
        case "IpcMode": return (value as? String).map { ["", "private"].contains($0) } ?? false
        case "CgroupnsMode": return (value as? String).map { ["", "private"].contains($0) } ?? false
        case "PidMode", "UsernsMode", "UTSMode", "Cgroup", "VolumeDriver", "Isolation", "CgroupParent":
            return (value as? String)?.isEmpty ?? false
        default: break
        }
        if let flag = value as? Bool { return !flag }
        if let number = value as? NSNumber {
            // Docker clients send -1 as "unset" for MemorySwappiness/PidsLimit (the CLI always does).
            if number.doubleValue == -1, ["MemorySwappiness", "PidsLimit"].contains(key) { return true }
            return number.doubleValue == 0
        }
        // ConsoleSize is [0,0] on every CLI-originated create (no omitempty in the Go type).
        if let numbers = value as? [NSNumber], !numbers.isEmpty { return numbers.allSatisfy { $0.doubleValue == 0 } }
        if let text = value as? String { return text.isEmpty }
        if let list = value as? [Any] { return list.isEmpty }
        if let object = value as? [String: Any] { return object.isEmpty }
        return false
    }

    static func unsupportedHostConfigKeys(_ hostConfig: [String: Any]) -> [String] {
        hostConfig.compactMap { key, value in
            handledHostConfigKeys.contains(key) || isDefaultHostConfigValue(key: key, value: value) ? nil : key
        }.sorted()
    }

    static func applyHostConfig(
        _ hostConfig: [String: Any], networking: [String: Any]?, to config: inout ContainerConfiguration,
        networkHostname: String
    ) async throws -> [String] {
        var warnings: [String] = []
        let unsupported = unsupportedHostConfigKeys(hostConfig)
        guard unsupported.isEmpty else {
            throw BridgeHTTPError(
                status: .badRequest,
                message:
                    "HostConfig \(unsupported.joined(separator: ", ")) not supported by this engine "
                    + "(refusing to ignore it silently); see `docker-api-bridge support`")
        }

        func strings(_ key: String) -> [String] { (hostConfig[key] as? [String]) ?? [] }
        func invalid(_ error: Error) -> BridgeHTTPError {
            BridgeHTTPError(status: .badRequest, message: "\((error as? ContainerizationError)?.message ?? "\(error)")")
        }

        // Networking: a named network replaces the builtin attachment; aliases come from
        // NetworkingConfig.EndpointsConfig[<network>].Aliases (how Testcontainers sets them).
        if let mode = hostConfig["NetworkMode"] as? String, !["", "default", "bridge"].contains(mode) {
            if ["host", "none"].contains(mode) || mode.hasPrefix("container:") {
                throw BridgeHTTPError(status: .badRequest, message: "NetworkMode \(mode) is not supported by this engine")
            }
            let network: NetworkResource
            do {
                network = try await NetworkClient().get(id: mode)
            } catch let error as ContainerizationError where error.code == .notFound {
                throw BridgeHTTPError(status: .notFound, message: "network \(mode) not found")
            }
            let endpoints = (networking?["EndpointsConfig"] as? [String: Any])?[mode] as? [String: Any]
            let aliases = (endpoints?["Aliases"] as? [String]) ?? []
            config.networks = [
                AttachmentConfiguration(
                    network: network.id,
                    options: AttachmentOptions(hostname: networkHostname, macAddress: nil, mtu: 1280, aliases: aliases))
            ]
        }

        // DNS
        let dns = strings("Dns")
        if !dns.isEmpty || !strings("DnsSearch").isEmpty || !strings("DnsOptions").isEmpty {
            let existing = config.dns
            config.dns = ContainerConfiguration.DNSConfiguration(
                nameservers: dns.isEmpty ? (existing?.nameservers ?? []) : dns,
                domain: existing?.domain,
                searchDomains: strings("DnsSearch").isEmpty ? (existing?.searchDomains ?? []) : strings("DnsSearch"),
                options: strings("DnsOptions").isEmpty ? (existing?.options ?? []) : strings("DnsOptions"))
        }

        do {
            let caps = try Parser.capabilities(capAdd: strings("CapAdd"), capDrop: strings("CapDrop"))
            config.capAdd = caps.capAdd
            config.capDrop = caps.capDrop
            config.extraHosts = try Parser.extraHosts(strings("ExtraHosts"))
            if let sysctls = hostConfig["Sysctls"] as? [String: String] {
                for (key, value) in try Parser.sysctls(sysctls.map { "\($0.key)=\($0.value)" }) { config.sysctls[key] = value }
            }
            if let devices = hostConfig["Devices"] as? [[String: Any]], !devices.isEmpty {
                let specs = devices.compactMap { device -> String? in
                    guard let host = device["PathOnHost"] as? String else { return nil }
                    let container = (device["PathInContainer"] as? String) ?? host
                    let mode = (device["CgroupPermissions"] as? String) ?? "rwm"
                    return "\(host):\(container):\(mode)"
                }
                config.devices = try Parser.devices(specs)
            }
            if let tmpfs = hostConfig["Tmpfs"] as? [String: String], !tmpfs.isEmpty {
                config.mounts += try Parser.tmpfsMounts(tmpfs.keys.sorted())
            }
        } catch let error as BridgeHTTPError {
            throw error
        } catch {
            throw invalid(error)
        }

        if let size = (hostConfig["ShmSize"] as? NSNumber)?.uint64Value, size > 0 { config.shmSize = size }
        if (hostConfig["Init"] as? Bool) == true { config.useInit = true }
        if (hostConfig["ReadonlyRootfs"] as? Bool) == true { config.readOnly = true }
        // Privileged has no extra effect: each container already runs in its own VM. Accept it
        // (Testcontainers sets it for docker-in-docker) rather than failing the create, but tell
        // the API caller, as the CLI does, instead of letting it believe it was applied.
        if (hostConfig["Privileged"] as? Bool) == true {
            warnings.append("Privileged has no extra effect: each container already runs in its own VM")
        }
        return warnings
    }

    /// Docker's multiplexed-stream frame: `[stream_type, 0, 0, 0, size_be32] + payload`.
    /// `stream_type` is 1 for stdout and 2 for stderr.
    static func muxFrame(stream: UInt8, payload: Data) -> Data {
        var frame = Data([stream, 0, 0, 0])
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    private func handleExecInspect(execId: String, outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>)
        async throws
    {
        guard let session = await execSessions.get(execId) else {
            throw BridgeHTTPError(status: .notFound, message: "No such exec instance: \(execId)")
        }
        let payload: [String: Any] = [
            "ID": session.id,
            "Running": session.running,
            "ExitCode": session.exitCode ?? 0,
            "ProcessConfig": [
                "entrypoint": session.process.executable,
                "arguments": session.process.arguments,
                "tty": session.process.terminal,
            ],
            "ContainerID": session.containerId,
            "Pid": 0,
        ]
        try await writeJSONObject(payload, outbound: outbound)
    }

    private func handleImagesList(outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>) async throws {
        let images = try await ClientImage.list()
        let payload: [[String: Any]] = images.map { image in
            [
                "Id": image.digest,
                "RepoTags": [image.reference],
                "RepoDigests": ["\(image.reference)@\(image.digest)"],
                "Size": 0,
                "VirtualSize": 0,
                "Labels": [:] as [String: String],
            ]
        }
        try await writeJSONObject(payload, outbound: outbound)
    }

    /// Docker `POST /images/create?fromImage=` — pull an image (curated subset).
    private func handleImageCreate(query: [URLQueryItem], outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>)
        async throws
    {
        guard let fromImage = query.first(where: { $0.name == "fromImage" })?.value, !fromImage.isEmpty else {
            throw BridgeHTTPError(status: .badRequest, message: "fromImage query parameter is required")
        }
        let tag = query.first(where: { $0.name == "tag" })?.value
        let reference = tag.map { "\(fromImage):\($0)" } ?? fromImage
        let config = try await ClientHealthCheck.loadContainerSystemConfig()
        do {
            let image = try await ClientImage.pull(
                reference: reference, containerSystemConfig: config)
            // Docker streams progress JSON lines; curated bridge returns a single status object.
            try await writeJSONObject(
                [
                    "status": "Pull complete",
                    "id": image.reference,
                ],
                outbound: outbound
            )
        } catch {
            throw BridgeHTTPError(status: .internalServerError, message: "\(error)")
        }
    }

    private func handleImageDelete(
        name: String, force _: Bool, outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>
    ) async throws {
        let config = try await ClientHealthCheck.loadContainerSystemConfig()
        let decoded = name.removingPercentEncoding ?? name
        do {
            let (found, notFound) = try await ClientImage.get(names: [decoded], containerSystemConfig: config)
            if found.isEmpty {
                // Docker Engine returns 404 for missing images even with force=true.
                throw BridgeHTTPError(
                    status: .notFound, message: "No such image: \(decoded)")
            }
            _ = notFound
            var untagged: [[String: String]] = []
            for image in found {
                try await ClientImage.delete(reference: image.reference, garbageCollect: false)
                untagged.append(["Untagged": image.reference])
                untagged.append(["Deleted": image.digest])
            }
            try await writeJSONObject(untagged, outbound: outbound)
        } catch let error as BridgeHTTPError {
            throw error
        } catch {
            throw BridgeHTTPError(status: .internalServerError, message: "\(error)")
        }
    }

    /// Curated `POST /build`: apply a tar context, run `container build -t …`.
    private func handleBuild(
        query: [URLQueryItem], body: ByteBuffer, outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>
    ) async throws {
        let tags = query.filter { $0.name == "t" }.compactMap(\.value).filter { !$0.isEmpty }
        guard let primaryTag = tags.first else {
            throw BridgeHTTPError(status: .badRequest, message: "query parameter t (image tag) is required")
        }
        let dockerfile = query.first(where: { $0.name == "dockerfile" })?.value ?? "Dockerfile"
        let nocache = Self.queryBool(query, name: "nocache", default: false)

        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("bridge-build-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let tarURL = work.appendingPathComponent("context.tar")
        let contextURL = work.appendingPathComponent("context", isDirectory: true)
        try fm.createDirectory(at: contextURL, withIntermediateDirectories: true)
        // Cap interim bridge builds so a huge context cannot OOM the plugin.
        let maxBuildContextBytes = 512 * 1024 * 1024
        guard body.readableBytes <= maxBuildContextBytes else {
            throw BridgeHTTPError(
                status: .payloadTooLarge,
                message: "build context exceeds \(maxBuildContextBytes) bytes"
            )
        }
        // Write off the cooperative pool; body is already buffered by NIO.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
                do {
                    try Data(buffer: body).write(to: tarURL)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }

        let untar = Process()
        untar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        untar.arguments = ["-xf", tarURL.path, "-C", contextURL.path]
        untar.standardOutput = FileHandle.nullDevice
        untar.standardError = FileHandle.nullDevice
        try untar.run()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                untar.waitUntilExit()
                cont.resume()
            }
        }
        guard untar.terminationStatus == 0 else {
            throw BridgeHTTPError(status: .badRequest, message: "failed to extract build context tar")
        }

        let cli = Self.containerCLIPath()
        var args = ["build", "-t", primaryTag, "-f", dockerfile]
        for tag in tags.dropFirst() {
            args.append(contentsOf: ["-t", tag])
        }
        if nocache {
            args.append("--no-cache")
        }
        args.append(contextURL.path)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cli)
        proc.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        // Drain stdout/stderr concurrently while the child runs so a full pipe
        // buffer on either stream cannot deadlock waitUntilExit.
        final class PipeBuffer: @unchecked Sendable {
            var data = Data()
        }
        let stdoutBuf = PipeBuffer()
        let stderrBuf = PipeBuffer()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stdoutBuf.data = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stderrBuf.data = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                proc.waitUntilExit()
                group.wait()
                cont.resume()
            }
        }
        let outText = String(data: stdoutBuf.data, encoding: .utf8) ?? ""
        let errText = String(data: stderrBuf.data, encoding: .utf8) ?? ""
        let combined = outText + errText

        if proc.terminationStatus != 0 {
            let message = combined.trimmingCharacters(in: .whitespacesAndNewlines)
            try await writeJSONObject(
                ["error": message.isEmpty ? "build failed with status \(proc.terminationStatus)" : message],
                status: .internalServerError,
                outbound: outbound
            )
            return
        }

        // Docker build streams NDJSON; emit a short curated stream then aux.
        var lines: [Data] = []
        for chunk in combined.split(separator: "\n").prefix(50) {
            let obj: [String: Any] = ["stream": String(chunk) + "\n"]
            lines.append(try JSONSerialization.data(withJSONObject: obj))
        }
        lines.append(
            try JSONSerialization.data(withJSONObject: [
                "aux": ["ID": primaryTag]
            ] as [String: Any]))
        lines.append(try JSONSerialization.data(withJSONObject: ["stream": "Successfully built \(primaryTag)\n"]))
        var payload = Data()
        for line in lines {
            payload.append(line)
            payload.append(contentsOf: [0x0A])  // \n
        }
        try await writeData(payload, contentType: "application/json", status: .ok, outbound: outbound)
    }

    private static func containerCLIPath() -> String {
        if let env = ProcessInfo.processInfo.environment["CONTAINER_BIN"], !env.isEmpty {
            return env
        }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        // .../libexec/container/plugins/<plugin>/bin/<exe> → .../bin/container
        let candidate = exe.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("bin/container")
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate.path
        }
        return "container"
    }

    private func handleNetworksList(outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>) async throws {
        let networks = try await NetworkClient().list()
        let payload = networks.map { Self.dockerNetworkSummary($0) }
        try await writeJSONObject(payload, outbound: outbound)
    }

    private func handleNetworkInspect(id: String, outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>)
        async throws
    {
        do {
            let network = try await NetworkClient().get(id: id)
            try await writeJSONObject(Self.dockerNetworkSummary(network), outbound: outbound)
        } catch let error as ContainerizationError where error.code == .notFound {
            throw BridgeHTTPError(status: .notFound, message: "network \(id) not found")
        } catch {
            throw BridgeHTTPError(status: .internalServerError, message: "\(error)")
        }
    }

    private func handleNetworkCreate(body: ByteBuffer, outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>)
        async throws
    {
        let json = try Self.jsonObject(from: body)
        guard let name = json["Name"] as? String, !name.isEmpty else {
            throw BridgeHTTPError(status: .badRequest, message: "Name is required")
        }
        let labelsDict = (json["Labels"] as? [String: String]) ?? [:]
        let labels = try ResourceLabels(labelsDict)
        let config = try NetworkConfiguration(
            name: name,
            mode: .nat,
            labels: labels,
            plugin: "container-network-vmnet"
        )
        let resource = try await NetworkClient().create(configuration: config)
        try await writeJSONObject(
            ["Id": resource.id, "Warning": ""],
            status: .created,
            outbound: outbound
        )
    }

    private func handleNetworkDelete(id: String, outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>)
        async throws
    {
        do {
            try await NetworkClient().delete(id: id)
            try await writeEmpty(status: .noContent, outbound: outbound)
        } catch let error as ContainerizationError where error.code == .notFound {
            throw BridgeHTTPError(status: .notFound, message: "network \(id) not found")
        } catch {
            throw BridgeHTTPError(status: .internalServerError, message: "\(error)")
        }
    }

    private func handleVolumesList(outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>) async throws {
        let volumes = try await ClientVolume.list()
        let payload: [String: Any] = [
            "Volumes": volumes.map { Self.dockerVolumeSummary($0) },
            "Warnings": [] as [String],
        ]
        try await writeJSONObject(payload, outbound: outbound)
    }

    private func handleVolumeInspect(name: String, outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>)
        async throws
    {
        do {
            let volume = try await ClientVolume.inspect(name)
            try await writeJSONObject(Self.dockerVolumeSummary(volume), outbound: outbound)
        } catch let error as ContainerizationError where error.code == .notFound {
            throw BridgeHTTPError(status: .notFound, message: "get \(name): no such volume")
        } catch {
            throw BridgeHTTPError(status: .internalServerError, message: "\(error)")
        }
    }

    private func handleVolumeCreate(body: ByteBuffer, outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>)
        async throws
    {
        let json = try Self.jsonObject(from: body)
        guard let name = json["Name"] as? String, !name.isEmpty else {
            throw BridgeHTTPError(status: .badRequest, message: "Name is required")
        }
        let driver = (json["Driver"] as? String) ?? "local"
        let labels = (json["Labels"] as? [String: String]) ?? [:]
        let opts = (json["DriverOpts"] as? [String: String]) ?? [:]
        let volume = try await ClientVolume.create(name: name, driver: driver, driverOpts: opts, labels: labels)
        try await writeJSONObject(Self.dockerVolumeSummary(volume), status: .created, outbound: outbound)
    }

    private func handleVolumeDelete(name: String, outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>)
        async throws
    {
        do {
            try await ClientVolume.delete(name: name)
            try await writeEmpty(status: .noContent, outbound: outbound)
        } catch let error as ContainerizationError where error.code == .notFound {
            throw BridgeHTTPError(status: .notFound, message: "get \(name): no such volume")
        } catch {
            throw BridgeHTTPError(status: .internalServerError, message: "\(error)")
        }
    }

    private static func dockerNetworkSummary(_ network: NetworkResource) -> [String: Any] {
        let subnet = "\(network.status.ipv4Subnet)"
        let gateway = "\(network.status.ipv4Gateway)"
        return [
            "Name": network.name,
            "Id": network.id,
            "Created": ISO8601DateFormatter().string(from: network.creationDate),
            "Scope": "local",
            "Driver": network.configuration.mode.rawValue,
            "EnableIPv6": false,
            "IPAM": [
                "Driver": "default",
                "Config": [["Subnet": subnet, "Gateway": gateway]],
            ] as [String: Any],
            "Internal": network.configuration.mode == .hostOnly,
            "Attachable": true,
            "Ingress": false,
            "Containers": [:] as [String: Any],
            "Options": network.configuration.options,
            // ResourceLabels is dictionary-backed; build without uniqueKeysWithValues trap risk.
            "Labels": Dictionary(network.labels.map { ($0.key, $0.value) }, uniquingKeysWith: { _, last in last }),
        ]
    }

    private static func dockerVolumeSummary(_ volume: VolumeConfiguration) -> [String: Any] {
        [
            "Name": volume.name,
            "Driver": volume.driver,
            "Mountpoint": volume.source,
            "CreatedAt": ISO8601DateFormatter().string(from: volume.creationDate),
            "Status": [:] as [String: String],
            "Labels": volume.labels,
            "Scope": "local",
            "Options": volume.options,
        ]
    }

    // MARK: - Mapping helpers

    /// Prefer Name; fall back to Id so Docker clients never see an empty `/` name.
    private static func displayName(for snap: ContainerSnapshot) -> String {
        let name = snap.configuration.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? snap.configuration.id : name
    }

    private func publishedPorts(_ snap: ContainerSnapshot) -> [[String: Any]] {
        snap.configuration.publishedPorts.map { port in
            [
                "IP": "\(port.hostAddress)",
                "PrivatePort": port.containerPort,
                "PublicPort": port.hostPort,
                "Type": port.proto.rawValue.lowercased(),
            ] as [String: Any]
        }
    }

    private func dockerPorts(_ snap: ContainerSnapshot) -> [String: Any] {
        var result: [String: Any] = [:]
        for port in snap.configuration.publishedPorts {
            let key = "\(port.containerPort)/\(port.proto.rawValue.lowercased())"
            result[key] = [
                [
                    "HostIp": "\(port.hostAddress)",
                    "HostPort": "\(port.hostPort)",
                ]
            ]
        }
        return result
    }

    private func dockerNetworks(_ snap: ContainerSnapshot) -> [String: Any] {
        var result: [String: Any] = [:]
        for attachment in snap.networks {
            result[attachment.network] = [
                "NetworkID": attachment.network,
                "IPAddress": attachment.ipv4Address.address.description,
                "Gateway": "\(attachment.ipv4Gateway)",
                "MacAddress": attachment.macAddress.map { "\($0)" } ?? "",
            ]
        }
        return result
    }

    /// `/containers/{id}` with a single non-empty id segment (no nested subresources).
    private static func isExactContainerResourcePath(_ path: String) -> Bool {
        guard path.hasPrefix("/containers/") else { return false }
        let rest = String(path.dropFirst("/containers/".count))
        return isSafeContainerID(rest)
    }

    /// `{id}` from `/containers/{id}{suffix}` when `{id}` is a single path segment.
    private func containerID(from path: String, suffix: String) -> String? {
        let trimmed = String(path.dropFirst("/containers/".count))
        guard trimmed.hasSuffix(suffix) else { return nil }
        let id = String(trimmed.dropLast(suffix.count))
        guard Self.isSafeContainerID(id) else { return nil }
        return id
    }

    /// `{id}` from `/exec/{id}{suffix}` when `{id}` is a single path segment.
    private func execID(from path: String, suffix: String) -> String? {
        let trimmed = String(path.dropFirst("/exec/".count))
        guard trimmed.hasSuffix(suffix) else { return nil }
        let id = String(trimmed.dropLast(suffix.count))
        guard Self.isSafeContainerID(id) else { return nil }
        return id
    }

    /// Reject empty ids, path separators, and any percent-encoding (including `%252f`).
    private static func isSafeContainerID(_ id: String) -> Bool {
        !id.isEmpty && !id.contains("/") && !id.contains("%")
    }

    // MARK: - Create / exec mapping

    private static func jsonObject(from body: ByteBuffer) throws -> [String: Any] {
        let data = Data(body.readableBytesView)
        if data.isEmpty {
            return [:]
        }
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dict = object as? [String: Any] else {
            throw BridgeHTTPError(status: .badRequest, message: "JSON object body required")
        }
        return dict
    }

    private static func processConfiguration(
        from json: [String: Any],
        imageConfig: ContainerizationOCI.ImageConfig?
    ) throws -> ProcessConfiguration {
        let imageEnv = imageConfig?.env ?? []
        let requestEnv = (json["Env"] as? [String]) ?? []
        let environment = try Parser.allEnv(imageEnvs: imageEnv, envFiles: [], envs: requestEnv)

        let workingDir: String = {
            if let cwd = json["WorkingDir"] as? String, !cwd.isEmpty {
                return cwd
            }
            return imageConfig?.workingDir ?? "/"
        }()

        var command: [String] = []
        let entrypointOverride = json["Entrypoint"] as? [String]
        if let entrypointOverride {
            command = entrypointOverride.filter { !$0.isEmpty }
        } else if let entrypoint = imageConfig?.entrypoint, !entrypoint.isEmpty, entrypoint != [""] {
            command = entrypoint
        }
        if let cmd = json["Cmd"] as? [String] {
            command.append(contentsOf: cmd)
        } else if entrypointOverride == nil, let cmd = imageConfig?.cmd, !cmd.isEmpty {
            command.append(contentsOf: cmd)
        }
        guard let executable = command.first, !executable.isEmpty else {
            throw BridgeHTTPError(
                status: .badRequest, message: "command/entrypoint not specified for container process")
        }

        let user: ProcessConfiguration.User = {
            if let raw = json["User"] as? String, !raw.isEmpty {
                return .raw(userString: raw)
            }
            if let raw = imageConfig?.user, !raw.isEmpty {
                return .raw(userString: raw)
            }
            return .id(uid: 0, gid: 0)
        }()

        let tty = (json["Tty"] as? Bool) ?? false
        return ProcessConfiguration(
            executable: executable,
            arguments: Array(command.dropFirst()),
            environment: environment,
            workingDirectory: workingDir.isEmpty ? "/" : workingDir,
            terminal: tty,
            user: user
        )
    }

    private static func resources(
        from hostConfig: [String: Any],
        defaults: ContainerConfig
    ) -> ContainerConfiguration.Resources {
        var resources = ContainerConfiguration.Resources()
        resources.cpus = defaults.cpus
        resources.memoryInBytes = defaults.memory.toUInt64(unit: .bytes)

        if let memory = hostConfig["Memory"] as? NSNumber, memory.int64Value > 0 {
            resources.memoryInBytes = UInt64(memory.int64Value)
        }
        if let nano = hostConfig["NanoCpus"] as? NSNumber, nano.int64Value > 0 {
            // Docker NanoCpus: 1e9 == 1 CPU. Round up to at least 1.
            // Use saturating divide to avoid Int64 overflow traps on huge inputs.
            let nanoValue = nano.int64Value
            let perCPU: Int64 = 1_000_000_000
            let cpus64 = nanoValue / perCPU + (nanoValue % perCPU == 0 ? 0 : 1)
            let cpus = Int(clamping: max(cpus64, 1))
            resources.cpus = max(cpus, 1)
        }
        return resources
    }

    private static func portBindings(from raw: Any?) throws -> [PublishPort] {
        guard let map = raw as? [String: Any] else { return [] }
        var ports: [PublishPort] = []
        for (key, value) in map {
            let parts = key.split(separator: "/", maxSplits: 1)
            guard !parts.isEmpty, let containerPort = UInt16(parts[0]), containerPort > 0 else {
                throw BridgeHTTPError(status: .badRequest, message: "invalid PortBindings key \(key)")
            }
            let protoRaw = parts.count == 2 ? String(parts[1]) : "tcp"
            guard let proto = PublishProtocol(protoRaw) else {
                throw BridgeHTTPError(
                    status: .badRequest, message: "unsupported PortBindings protocol in \(key)")
            }
            let bindings = value as? [[String: Any]] ?? []
            for binding in bindings {
                let hostPortRaw = (binding["HostPort"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let hostPort: UInt16
                if hostPortRaw.isEmpty || hostPortRaw == "0" {
                    // Leave 0 so RuntimeService/TCPForwarder binds with an ephemeral
                    // port while holding the listen FD (avoids allocate-then-close TOCTOU).
                    hostPort = 0
                } else {
                    guard let parsed = UInt16(hostPortRaw), parsed > 0 else {
                        throw BridgeHTTPError(
                            status: .badRequest, message: "invalid HostPort for PortBindings \(key)")
                    }
                    hostPort = parsed
                }
                let hostIpRaw = (binding["HostIp"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let hostIp = (hostIpRaw?.isEmpty == false) ? hostIpRaw! : "0.0.0.0"
                let hostAddress = try IPAddress(hostIp)
                try ports.append(
                    PublishPort(
                        hostAddress: hostAddress,
                        hostPort: hostPort,
                        containerPort: containerPort,
                        proto: proto,
                        count: 1
                    ))
            }
        }
        return ports
    }

    private static func binds(from raw: Any?) throws -> [Filesystem] {
        guard let binds = raw as? [String] else { return [] }
        var mounts: [Filesystem] = []
        for bind in binds {
            // Interim subset: require absolute POSIX host paths (leading /). Reject
            // colon-ambiguous sources rather than mis-parsing them.
            let parts = bind.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2 else {
                throw BridgeHTTPError(status: .badRequest, message: "invalid bind \(bind)")
            }
            let source = parts[0]
            let destination = parts[1]
            var options: MountOptions = []
            if parts.count == 3 {
                options = parts[2].split(separator: ",").map(String.init)
            }
            guard source.hasPrefix("/") else {
                throw BridgeHTTPError(
                    status: .badRequest,
                    message: "bind source must be an absolute host path for the create subset: \(bind)"
                )
            }
            guard destination.hasPrefix("/") else {
                throw BridgeHTTPError(
                    status: .badRequest,
                    message: "bind destination must be an absolute container path: \(bind)"
                )
            }
            mounts.append(Filesystem.virtiofs(source: source, destination: destination, options: options))
        }
        return mounts
    }

    private static func restartPolicy(from raw: Any?) throws -> RestartPolicy.Parsed? {
        guard let dict = raw as? [String: Any] else { return nil }
        let name = ((dict["Name"] as? String) ?? "").lowercased()
        if name.isEmpty || name == "no" {
            return RestartPolicy.Parsed(policy: .no, maximumRetryCount: nil)
        }
        guard let policy = RestartPolicy(rawValue: name) else {
            throw BridgeHTTPError(
                status: .badRequest, message: "unsupported RestartPolicy.Name \(name)")
        }
        var maxRetries: UInt64?
        if let count = dict["MaximumRetryCount"] as? NSNumber {
            maxRetries = count.uint64Value
        }
        return RestartPolicy.Parsed(
            policy: policy,
            maximumRetryCount: policy == .onFailure ? maxRetries : nil
        )
    }

    // MARK: - HTTP helpers

    private static func path(from uri: String) -> String {
        URLComponents(string: uri)?.path ?? uri
    }

    private static func queryItems(from uri: String) -> [URLQueryItem] {
        URLComponents(string: uri)?.queryItems ?? []
    }

    private static func queryBool(_ items: [URLQueryItem], name: String, default defaultValue: Bool) -> Bool {
        guard let item = items.first(where: { $0.name == name }) else {
            return defaultValue
        }
        // Docker treats a present boolean flag with an empty value as true (`?force=`).
        let raw = (item.value ?? "").lowercased()
        if raw.isEmpty { return true }
        return raw == "1" || raw == "true" || raw == "yes"
    }

    private static func stripAPIVersion(_ path: String) -> String {
        // /v1.43/containers/json → /containers/json. Require `v` + digits/dots only.
        guard path.hasPrefix("/v") else { return path }
        let rest = path.dropFirst(2)  // drop "/v"
        guard let slash = rest.firstIndex(of: "/") else { return path }
        let version = rest[..<slash]
        guard !version.isEmpty, version.allSatisfy({ $0.isNumber || $0 == "." }) else { return path }
        return String(rest[slash...])
    }

    private static func versionPayload() -> [String: Any] {
        [
            "Version": "container-bridge",
            "ApiVersion": "1.43",
            "MinAPIVersion": "1.24",
            "Os": "linux",
            "Arch": "arm64",
            "KernelVersion": "container",
            "GoVersion": "swift",
            "Experimental": true,
            "Components": [
                [
                    "Name": "Engine",
                    "Version": "container-docker-api-bridge",
                ]
            ],
        ]
    }

    private static func infoPayload() -> [String: Any] {
        [
            "ID": "container",
            "Containers": 0,
            "ContainersRunning": 0,
            "Images": 0,
            "Driver": "container",
            "Name": "container-docker-api-bridge",
            "OperatingSystem": "macOS (container)",
            "OSType": "linux",
            "Architecture": "aarch64",
            "NCPU": ProcessInfo.processInfo.processorCount,
            "MemTotal": 0,
            "ServerVersion": "container-bridge",
        ]
    }

    private func writeUnsupported(method: HTTPMethod, path: String, outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>) async throws {
        try await writeJSONObject(
            [
                "message":
                    "route \(method) \(path) is outside the curated Engine bridge contract (501 by design; see `docker-api-bridge support`)"
            ],
            status: .notImplemented,
            outbound: outbound
        )
    }

    private func writeJSONObject(_ object: Any, status: HTTPResponseStatus = .ok, outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>) async throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try await writeData(data, contentType: "application/json", status: status, outbound: outbound)
    }

    private func writeText(
        _ text: String, status: HTTPResponseStatus, outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>, headOnly: Bool = false
    ) async throws {
        let data = Data(text.utf8)
        try await writeData(data, contentType: "text/plain; charset=utf-8", status: status, outbound: outbound, headOnly: headOnly)
    }

    private func writeEmpty(status: HTTPResponseStatus, outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>) async throws {
        try await writeData(Data(), contentType: "text/plain", status: status, outbound: outbound)
    }

    private func writeData(
        _ data: Data,
        contentType: String,
        status: HTTPResponseStatus = .ok,
        outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>,
        headOnly: Bool = false
    ) async throws {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: contentType)
        headers.add(name: "Content-Length", value: "\(data.count)")
        headers.add(name: "Server", value: "container-docker-api-bridge")
        try await outbound.write(
            .head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))
        )
        if !headOnly, !data.isEmpty {
            var buffer = ByteBufferAllocator().buffer(capacity: data.count)
            buffer.writeBytes(data)
            try await outbound.write(.body(.byteBuffer(buffer)))
        }
        try await outbound.write(.end(nil))
    }
}

struct BridgeHTTPError: Error {
    let status: HTTPResponseStatus
    let message: String
}

/// In-memory Docker exec instance store (create → start → inspect).
private actor ExecSessionStore {
    struct Session: Sendable {
        let id: String
        let containerId: String
        let process: ProcessConfiguration
        var started: Bool
        var running: Bool
        var exitCode: Int32?
    }

    private var sessions: [String: Session] = [:]
    private static let maxSessions = 256

    enum CreateResult: Sendable {
        case created(String)
        case capacityExceeded
    }

    func create(containerId: String, process: ProcessConfiguration) -> CreateResult {
        // Bound memory: drop finished sessions only. Never evict running sessions.
        if sessions.count >= Self.maxSessions {
            let finished = sessions.filter { $0.value.exitCode != nil }.map(\.key)
            for key in finished {
                sessions.removeValue(forKey: key)
            }
        }
        if sessions.count >= Self.maxSessions {
            let idle = sessions.filter { !$0.value.started && $0.value.exitCode == nil }.map(\.key)
            for key in idle.prefix(max(1, sessions.count - Self.maxSessions + 1)) {
                sessions.removeValue(forKey: key)
            }
        }
        guard sessions.count < Self.maxSessions else {
            return .capacityExceeded
        }
        let id = UUID().uuidString.lowercased()
        sessions[id] = Session(
            id: id,
            containerId: containerId,
            process: process,
            started: false,
            running: false,
            exitCode: nil
        )
        return .created(id)
    }

    func get(_ id: String) -> Session? {
        sessions[id]
    }

    enum ClaimResult: Sendable {
        case notFound
        case alreadyStarted
        case claimed(Session)
    }

    /// Atomically mark an exec session started, or report why it cannot start.
    func claimStart(_ id: String) -> ClaimResult {
        guard var session = sessions[id] else { return .notFound }
        if session.started { return .alreadyStarted }
        session.started = true
        session.running = true
        sessions[id] = session
        return .claimed(session)
    }

    /// Undo a failed start claim so a later retry can succeed.
    func resetClaim(_ id: String) {
        guard var session = sessions[id], session.exitCode == nil else { return }
        session.started = false
        session.running = false
        sessions[id] = session
    }

    func markFinished(_ id: String, exitCode: Int32) {
        guard var session = sessions[id] else { return }
        session.running = false
        session.exitCode = exitCode
        session.started = true
        sessions[id] = session
    }
}
