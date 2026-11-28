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
import ContainerAPIClient
import ContainerResource
import ContainerizationOCI
import Foundation

extension Application {
    /// Runs container / image / network (and optional volume) prune in one command,
    /// matching Docker's `system prune` shape.
    public struct SystemPrune: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "prune",
            abstract: "Remove unused data (stopped containers, unused networks, dangling images)"
        )

        @OptionGroup
        public var logOptions: Flags.Logging

        @Flag(name: .shortAndLong, help: "Remove all unused images, not just dangling ones")
        var all: Bool = false

        @Flag(name: .long, help: "Also prune unused volumes")
        var volumes: Bool = false

        public func run() async throws {
            var totalBytes: UInt64 = 0
            totalBytes += try await pruneContainers()
            try await pruneNetworks()
            totalBytes += try await pruneImages(all: all)
            if volumes {
                totalBytes += try await pruneVolumes()
            }

            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            log.info("Total reclaimed space: \(formatter.string(fromByteCount: Int64(totalBytes)))")
        }

        private func pruneContainers() async throws -> UInt64 {
            let client = ContainerClient()
            let filters = ContainerListFilters(status: .stopped).withoutPlugins([
                ResourcePluginValues.machine, ResourcePluginValues.cluster,
            ])
            let containers = try await client.list(filters: filters)
            var deleted: [String] = []
            var total: UInt64 = 0
            for container in containers {
                do {
                    total += try await client.diskUsage(id: container.id)
                    try await client.delete(id: container.id)
                    deleted.append(container.id)
                } catch {
                    log.error(
                        "failed to prune container",
                        metadata: ["id": "\(container.id)", "error": "\(error)"])
                }
            }
            if !deleted.isEmpty {
                print("Deleted Containers:")
                deleted.forEach { print($0) }
            }
            return total
        }

        private func pruneNetworks() async throws {
            let networkClient = NetworkClient()
            let client = ContainerClient()
            let allContainers = try await client.list()
            let allNetworks = try await networkClient.list()
            var inUse = Set<String>()
            for container in allContainers {
                for network in container.configuration.networks {
                    inUse.insert(network.network)
                }
            }
            var deleted: [String] = []
            for network in allNetworks where !network.isBuiltin && !inUse.contains(network.id) {
                do {
                    try await networkClient.delete(id: network.id)
                    deleted.append(network.id)
                } catch {
                    log.error(
                        "failed to prune network",
                        metadata: ["id": "\(network.id)", "error": "\(error)"])
                }
            }
            if !deleted.isEmpty {
                print("Deleted Networks:")
                deleted.forEach { print($0) }
            }
        }

        private func pruneImages(all: Bool) async throws -> UInt64 {
            let allImages = try await ClientImage.list()
            let imagesToPrune: [ClientImage]
            if all {
                let client = ContainerClient()
                let containers = try await client.list()
                var imagesInUse = Set<String>()
                for container in containers {
                    imagesInUse.insert(container.configuration.image.reference)
                }
                imagesToPrune = allImages.filter { !imagesInUse.contains($0.reference) }
            } else {
                imagesToPrune = allImages.filter { !hasTag($0.reference) }
            }

            var untagged: [String] = []
            for image in imagesToPrune {
                do {
                    try await ClientImage.delete(reference: image.reference, garbageCollect: false)
                    untagged.append(image.reference)
                } catch {
                    log.error(
                        "failed to prune image",
                        metadata: ["ref": "\(image.reference)", "error": "\(error)"])
                }
            }
            let (digests, size) = try await ClientImage.cleanUpOrphanedBlobs()
            if !untagged.isEmpty || !digests.isEmpty {
                print("Deleted Images:")
                untagged.forEach { print("untagged: \($0)") }
                digests.forEach { print("deleted: \($0)") }
            }
            return size
        }

        private func pruneVolumes() async throws -> UInt64 {
            let allVolumes = try await ClientVolume.list()
            let client = ContainerClient()
            let containers = try await client.list()
            var inUse = Set<String>()
            for container in containers {
                for mount in container.configuration.mounts where mount.isVolume {
                    if let name = mount.volumeName {
                        inUse.insert(name)
                    }
                }
            }
            var deleted: [String] = []
            var total: UInt64 = 0
            for volume in allVolumes where !inUse.contains(volume.name) {
                do {
                    total += try await ClientVolume.volumeDiskUsage(name: volume.name)
                    try await ClientVolume.delete(name: volume.name)
                    deleted.append(volume.name)
                } catch {
                    log.error(
                        "failed to prune volume",
                        metadata: ["id": "\(volume.name)", "error": "\(error)"])
                }
            }
            if !deleted.isEmpty {
                print("Deleted Volumes:")
                deleted.forEach { print($0) }
            }
            return total
        }

        private func hasTag(_ reference: String) -> Bool {
            do {
                let ref = try ContainerizationOCI.Reference.parse(reference)
                return ref.tag != nil && !(ref.tag?.isEmpty ?? true)
            } catch {
                return false
            }
        }
    }
}
