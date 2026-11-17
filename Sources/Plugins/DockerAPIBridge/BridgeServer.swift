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
import ContainerResource
import ContainerizationError
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
        Supported (curated subset):
          GET  /_ping
          GET  /version
          GET  /info
          GET  /containers/json
          GET  /containers/{id}/json
          GET  /containers/{id}/logs
          POST /containers/{id}/start
          POST /containers/{id}/stop
          POST /containers/{id}/kill
          POST /containers/{id}/wait
          DELETE /containers/{id}
          GET  /images/json

        Unsupported routes return HTTP 501 with a stable JSON error body.
        Create/build/exec/events/networks/volumes are not implemented here yet —
        use the `container` CLI, Socktainer, or extend this plugin.
        API version prefixes (/v1.41/...) are accepted and stripped.
        """

    let socketPath: String
    let log: Logger

    init(socketPath: String, log: Logger) {
        self.socketPath = socketPath
        self.log = log
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
                try await handleContainerLogs(id: id, outbound: outbound)
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
            case (.DELETE, let p) where Self.isExactContainerResourcePath(p):
                // Exact `/containers/{id}` only — any extra path segment is a subresource (501).
                let id = String(p.dropFirst("/containers/".count))
                let force = Self.queryBool(query, name: "force", default: false)
                try await handleContainerDelete(id: id, force: force, outbound: outbound)
            case (.GET, "/images/json"):
                try await handleImagesList(outbound: outbound)
            default:
                try await writeUnsupported(method: method, path: path, outbound: outbound)
            }
        } catch let error as BridgeHTTPError {
            try await writeJSONObject(
                ["message": error.message],
                status: error.status,
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
            [
                "Id": snap.configuration.id,
                "Names": ["/\(snap.configuration.id)"],
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

    private func handleContainerInspect(id: String, outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>) async throws {
        let client = ContainerClient()
        let snap: ContainerSnapshot
        do {
            snap = try await client.get(id: id)
        } catch {
            throw BridgeHTTPError(status: .notFound, message: "No such container: \(id)")
        }
        let health: [String: Any]? = {
            guard snap.configuration.healthcheck != nil else { return nil }
            return [
                "Status": snap.configuration.healthStatus.rawValue
            ]
        }()
        // Pid is unavailable over this curated bridge. ExitCode is 0 while running;
        // when stopped the runtime snapshot does not persist the last code, so report -1
        // rather than claiming a successful exit (clients should use /wait for the real code).
        var state: [String: Any] = [
            "Status": snap.status.rawValue,
            "Running": snap.status == .running,
            "Pid": 0,
            "ExitCode": snap.status == .running ? 0 : -1,
        ]
        if let health { state["Health"] = health }
        let payload: [String: Any] = [
            "Id": snap.configuration.id,
            "Name": "/\(snap.configuration.id)",
            "Created": ISO8601DateFormatter().string(from: snap.configuration.creationDate),
            "Path": snap.configuration.initProcess.executable,
            "Args": snap.configuration.initProcess.arguments,
            "State": state,
            "Image": snap.configuration.image.digest,
            "Config": [
                "Hostname": snap.configuration.id,
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

    private func handleContainerLogs(id: String, outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>) async throws {
        let client = ContainerClient()
        _ = try await client.get(id: id)
        let handles = try await client.logs(id: id)
        // Empty log set is a successful empty body (Docker-compatible), not 404.
        var data = Data()
        for handle in handles {
            if let chunk = try handle.readToEnd() {
                data.append(chunk)
            }
        }
        try await writeData(data, contentType: "text/plain; charset=utf-8", outbound: outbound)
    }

    private func handleContainerStart(id: String, outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>) async throws {
        let client = ContainerClient()
        let snap = try await client.get(id: id)
        if snap.status == .running {
            try await writeEmpty(status: .notModified, outbound: outbound)
            return
        }
        _ = try await client.bootstrap(id: id, stdio: [nil, nil, nil])
        let process = client.initProcess(id: id)
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
        } catch let error as ContainerizationError where error.code == .invalidState && !force {
            throw BridgeHTTPError(
                status: .conflict, message: "cannot remove a running container \(id); use force=1")
        }
        try await writeEmpty(status: .noContent, outbound: outbound)
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

    // MARK: - Mapping helpers

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

    /// Reject empty ids, path separators, and any percent-encoding (including `%252f`).
    private static func isSafeContainerID(_ id: String) -> Bool {
        !id.isEmpty && !id.contains("/") && !id.contains("%")
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
                    "route \(method) \(path) is not implemented by container-docker-api-bridge (curated subset; see `docker-api-bridge support`)"
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

private struct BridgeHTTPError: Error {
    let status: HTTPResponseStatus
    let message: String
}
