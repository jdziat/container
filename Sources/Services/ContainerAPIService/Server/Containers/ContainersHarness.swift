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

import ContainerResource
import ContainerXPC
import Containerization
import ContainerizationError
import ContainerizationOS
import Foundation
import Logging

public struct ContainersHarness: Sendable {
    let log: Logging.Logger
    let service: ContainersService

    public init(service: ContainersService, log: Logging.Logger) {
        self.log = log
        self.service = service
    }

    @Sendable
    public func list(_ message: XPCMessage) async throws -> XPCMessage {
        var filters = ContainerListFilters.all
        if let filterData = message.dataNoCopy(key: .listFilters) {
            filters = try JSONDecoder().decode(ContainerListFilters.self, from: filterData)
        }
        let containers = try await service.list(filters: filters)
        let data = try JSONEncoder().encode(containers)

        let reply = message.reply()
        reply.set(key: .containers, value: data)
        return reply
    }

    @Sendable
    public func bootstrap(_ message: XPCMessage) async throws -> XPCMessage {
        let id = message.string(key: .id)
        guard let id else {
            throw ContainerizationError(
                .invalidArgument,
                message: "id cannot be empty"
            )
        }
        guard ManagedContainer.nameValid(id) else {
            throw ContainerizationError(.invalidArgument, message: "container ID \(id) is not a valid container ID")
        }
        let stdio = message.stdio()

        let data = message.dataNoCopy(key: .dynamicEnv)
        let env = try data.map { try JSONDecoder().decode([String: String].self, from: $0) } ?? [:]

        try await service.bootstrap(id: id, stdio: stdio, dynamicEnv: env)
        return message.reply()
    }

    @Sendable
    public func stop(_ message: XPCMessage) async throws -> XPCMessage {
        let stopOptions = try message.stopOptions()
        let id = message.string(key: .id)
        guard let id else {
            throw ContainerizationError(
                .invalidArgument,
                message: "id cannot be empty"
            )
        }
        try await service.stop(id: id, options: stopOptions)
        return message.reply()
    }

    @Sendable
    public func dial(_ message: XPCMessage) async throws -> XPCMessage {
        let id = message.string(key: .id)
        guard let id else {
            throw ContainerizationError(
                .invalidArgument,
                message: "id cannot be empty"
            )
        }

        let port = message.uint64(key: .port)
        let fh = try await service.dial(id: id, port: UInt32(port))
        let reply = message.reply()
        reply.setFileHandle(fh)

        return reply
    }

    @Sendable
    public func wait(_ message: XPCMessage) async throws -> XPCMessage {
        let id = message.string(key: .id)
        guard let id else {
            throw ContainerizationError(
                .invalidArgument,
                message: "id cannot be empty"
            )
        }
        let processID = message.string(key: .processIdentifier)
        guard let processID else {
            throw ContainerizationError(
                .invalidArgument,
                message: "process ID cannot be empty"
            )
        }

        let exitStatus = try await service.wait(id: id, processID: processID)
        let reply = message.reply()
        reply.set(key: .exitCode, value: Int64(exitStatus.exitCode))
        reply.set(key: .exitedAt, value: exitStatus.exitedAt)
        return reply
    }

    @Sendable
    public func resize(_ message: XPCMessage) async throws -> XPCMessage {
        let id = message.string(key: .id)
        guard let id else {
            throw ContainerizationError(
                .invalidArgument,
                message: "id cannot be empty"
            )
        }
        let processID = message.string(key: .processIdentifier)
        guard let processID else {
            throw ContainerizationError(
                .invalidArgument,
                message: "process ID cannot be empty"
            )
        }

        let width = message.uint64(key: .width)
        let height = message.uint64(key: .height)
        try await service.resize(
            id: id,
            processID: processID,
            size: Terminal.Size(width: UInt16(width), height: UInt16(height))
        )

        return message.reply()
    }

    @Sendable
    public func kill(_ message: XPCMessage) async throws -> XPCMessage {
        let id = message.string(key: .id)
        guard let id else {
            throw ContainerizationError(
                .invalidArgument,
                message: "id cannot be empty"
            )
        }
        let processID = message.string(key: .processIdentifier)
        guard let processID else {
            throw ContainerizationError(
                .invalidArgument,
                message: "process ID cannot be empty"
            )
        }
        try await service.kill(
            id: id,
            processID: processID,
            signal: try message.signal()
        )
        return message.reply()
    }

    @Sendable
    public func create(_ message: XPCMessage) async throws -> XPCMessage {
        let data = message.dataNoCopy(key: .containerConfig)
        guard let data else {
            throw ContainerizationError(
                .invalidArgument,
                message: "container configuration cannot be empty"
            )
        }
        let kdata = message.dataNoCopy(key: .kernel)
        guard let kdata else {
            throw ContainerizationError(
                .invalidArgument,
                message: "kernel cannot be empty"
            )
        }
        let odata = message.dataNoCopy(key: .containerOptions)
        var options: ContainerCreateOptions = .default
        if let odata {
            options = try JSONDecoder().decode(ContainerCreateOptions.self, from: odata)
        }
        let config = try JSONDecoder().decode(ContainerConfiguration.self, from: data)
        guard ManagedContainer.nameValid(config.id) else {
            throw ContainerizationError(.invalidArgument, message: "container ID \(config.id) is not a valid container ID")
        }
        let kernel = try JSONDecoder().decode(Kernel.self, from: kdata)

        let initImage = message.string(key: .initImage)
        let runtimeData = message.dataNoCopy(key: .runtimeData)

        try await service.create(configuration: config, kernel: kernel, options: options, initImage: initImage, runtimeData: runtimeData)
        return message.reply()
    }

    @Sendable
    public func createProcess(_ message: XPCMessage) async throws -> XPCMessage {
        let id = message.string(key: .id)
        guard let id else {
            throw ContainerizationError(
                .invalidArgument,
                message: "id cannot be empty"
            )
        }
        let processID = message.string(key: .processIdentifier)
        guard let processID else {
            throw ContainerizationError(
                .invalidArgument,
                message: "process ID cannot be empty"
            )
        }
        let config = try message.processConfig()
        let stdio = message.stdio()

        try await service.createProcess(
            id: id,
            processID: processID,
            config: config,
            stdio: stdio
        )

        return message.reply()
    }

    @Sendable
    public func startProcess(_ message: XPCMessage) async throws -> XPCMessage {
        let id = message.string(key: .id)
        guard let id else {
            throw ContainerizationError(
                .invalidArgument,
                message: "id cannot be empty"
            )
        }
        let processID = message.string(key: .processIdentifier)
        guard let processID else {
            throw ContainerizationError(
                .invalidArgument,
                message: "process ID cannot be empty"
            )
        }

        try await service.startProcess(
            id: id,
            processID: processID,
        )

        return message.reply()
    }

    @Sendable
    public func delete(_ message: XPCMessage) async throws -> XPCMessage {
        let id = message.string(key: .id)
        guard let id else {
            throw ContainerizationError(.invalidArgument, message: "id cannot be empty")
        }
        guard ManagedContainer.nameValid(id) else {
            throw ContainerizationError(.invalidArgument, message: "container ID \(id) is not a valid container ID")
        }
        let forceDelete = message.bool(key: .forceDelete)
        try await service.delete(id: id, force: forceDelete)
        return message.reply()
    }

    @Sendable
    public func diskUsage(_ message: XPCMessage) async throws -> XPCMessage {
        guard let containerId = message.string(key: .id) else {
            throw ContainerizationError(.invalidArgument, message: "id cannot be empty")
        }
        guard ManagedContainer.nameValid(containerId) else {
            throw ContainerizationError(.invalidArgument, message: "container ID \(containerId) is not a valid container ID")
        }

        let size = try await service.containerDiskUsage(id: containerId)

        let reply = message.reply()
        reply.set(key: .containerSize, value: size)
        return reply
    }

    @Sendable
    public func logs(_ message: XPCMessage) async throws -> XPCMessage {
        let id = message.string(key: .id)
        guard let id else {
            throw ContainerizationError(
                .invalidArgument,
                message: "id cannot be empty"
            )
        }
        guard ManagedContainer.nameValid(id) else {
            throw ContainerizationError(.invalidArgument, message: "container ID \(id) is not a valid container ID")
        }
        let fds = try await service.logs(id: id)
        let reply = message.reply()
        try reply.set(key: .logs, value: fds)
        return reply
    }

    @Sendable
    public func copyIn(_ message: XPCMessage) async throws -> XPCMessage {
        guard let id = message.string(key: .id) else {
            throw ContainerizationError(
                .invalidArgument,
                message: "id cannot be empty"
            )
        }
        guard let sourcePath = message.string(key: .sourcePath) else {
            throw ContainerizationError(
                .invalidArgument,
                message: "source path cannot be empty"
            )
        }
        guard let destinationPath = message.string(key: .destinationPath) else {
            throw ContainerizationError(
                .invalidArgument,
                message: "destination path cannot be empty"
            )
        }
        let mode = UInt32(message.uint64(key: .fileMode))
        let createParents = message.bool(key: .createParents)

        try await service.copyIn(id: id, source: sourcePath, destination: destinationPath, mode: mode, createParents: createParents)
        return message.reply()
    }

    @Sendable
    public func copyOut(_ message: XPCMessage) async throws -> XPCMessage {
        guard let id = message.string(key: .id) else {
            throw ContainerizationError(
                .invalidArgument,
                message: "id cannot be empty"
            )
        }
        guard let sourcePath = message.string(key: .sourcePath) else {
            throw ContainerizationError(
                .invalidArgument,
                message: "source path cannot be empty"
            )
        }
        guard let destinationPath = message.string(key: .destinationPath) else {
            throw ContainerizationError(
                .invalidArgument,
                message: "destination path cannot be empty"
            )
        }

        let createParents = message.bool(key: .createParents)

        try await service.copyOut(id: id, source: sourcePath, destination: destinationPath, createParents: createParents)
        return message.reply()
    }

    @Sendable
    public func stats(_ message: XPCMessage) async throws -> XPCMessage {
        let id = message.string(key: .id)
        guard let id else {
            throw ContainerizationError(
                .invalidArgument,
                message: "id cannot be empty"
            )
        }
        let stats = try await service.stats(id: id)
        let data = try JSONEncoder().encode(stats)
        let reply = message.reply()
        reply.set(key: .statistics, value: data)
        return reply
    }

    @Sendable
    public func export(_ message: XPCMessage) async throws -> XPCMessage {
        let id = message.string(key: .id)
        guard let id else {
            throw ContainerizationError(
                .invalidArgument,
                message: "id cannot be empty"
            )
        }
        guard ManagedContainer.nameValid(id) else {
            throw ContainerizationError(.invalidArgument, message: "container ID \(id) is not a valid container ID")
        }
        let archive = message.string(key: .archive)
        guard let archive else {
            throw ContainerizationError(
                .invalidArgument,
                message: "archive cannot be empty"
            )
        }
        let archiveUrl = URL(fileURLWithPath: archive)

        try await service.exportRootfs(id: id, archive: archiveUrl)
        return message.reply()
    }

    @Sendable
    public func clean(_ message: XPCMessage) async throws -> XPCMessage {
        let id = message.string(key: .id)
        guard let id else {
            throw ContainerizationError(
                .invalidArgument,
                message: "id cannot be empty"
            )
        }

        try await service.clean(id: id)
        return message.reply()
    }

    @Sendable
    public func events(_ message: XPCMessage) async throws -> XPCMessage {
        let since = message.uint64(key: .eventSince)
        let events = await service.events(since: since)
        let data = try JSONEncoder().encode(events)
        let reply = message.reply()
        reply.set(key: .containerEvents, value: data)
        return reply
    }

    @Sendable
    public func rename(_ message: XPCMessage) async throws -> XPCMessage {
        let id = message.string(key: .id)
        guard let id else {
            throw ContainerizationError(.invalidArgument, message: "id cannot be empty")
        }
        let newName = message.string(key: .newName)
        guard let newName else {
            throw ContainerizationError(.invalidArgument, message: "new name cannot be empty")
        }
        try await service.rename(idOrName: id, newName: newName)
        return message.reply()
    }

    @Sendable
    public func update(_ message: XPCMessage) async throws -> XPCMessage {
        let id = message.string(key: .id)
        guard let id else {
            throw ContainerizationError(.invalidArgument, message: "id cannot be empty")
        }
        guard let data = message.dataNoCopy(key: .updateConfig) else {
            throw ContainerizationError(.invalidArgument, message: "update config cannot be empty")
        }
        let request = try JSONDecoder().decode(ContainerUpdateRequest.self, from: data)
        try await service.update(idOrName: id, request: request)
        return message.reply()
    }

    @Sendable
    public func pause(_ message: XPCMessage) async throws -> XPCMessage {
        let id = message.string(key: .id)
        guard let id else {
            throw ContainerizationError(.invalidArgument, message: "id cannot be empty")
        }
        try await service.pause(idOrName: id)
        return message.reply()
    }

    @Sendable
    public func unpause(_ message: XPCMessage) async throws -> XPCMessage {
        let id = message.string(key: .id)
        guard let id else {
            throw ContainerizationError(.invalidArgument, message: "id cannot be empty")
        }
        try await service.unpause(idOrName: id)
        return message.reply()
    }

    @Sendable
    public func diff(_ message: XPCMessage) async throws -> XPCMessage {
        let id = message.string(key: .id)
        guard let id else {
            throw ContainerizationError(.invalidArgument, message: "id cannot be empty")
        }
        let changes = try await service.diff(idOrName: id)
        let data = try JSONEncoder().encode(changes)
        let reply = message.reply()
        reply.set(key: .containerDiff, value: data)
        return reply
    }

    @Sendable
    public func networkConnect(_ message: XPCMessage) async throws -> XPCMessage {
        let id = message.string(key: .id)
        guard let id else {
            throw ContainerizationError(.invalidArgument, message: "id cannot be empty")
        }
        let network = message.string(key: .networkId)
        guard let network else {
            throw ContainerizationError(.invalidArgument, message: "network cannot be empty")
        }
        let aliases: [String]
        if let data = message.dataNoCopy(key: .networkAliases) {
            aliases = try JSONDecoder().decode([String].self, from: data)
        } else {
            aliases = []
        }
        let restart = message.bool(key: .restartIfRunning)
        try await service.networkConnect(
            idOrName: id, network: network, aliases: aliases, restartIfRunning: restart)
        return message.reply()
    }

    @Sendable
    public func networkDisconnect(_ message: XPCMessage) async throws -> XPCMessage {
        let id = message.string(key: .id)
        guard let id else {
            throw ContainerizationError(.invalidArgument, message: "id cannot be empty")
        }
        let network = message.string(key: .networkId)
        guard let network else {
            throw ContainerizationError(.invalidArgument, message: "network cannot be empty")
        }
        let restart = message.bool(key: .restartIfRunning)
        let force = message.bool(key: .forceDelete)
        try await service.networkDisconnect(
            idOrName: id, network: network, restartIfRunning: restart, force: force)
        return message.reply()
    }
}
