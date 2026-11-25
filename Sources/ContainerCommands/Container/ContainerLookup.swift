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

extension ContainerClient {
    /// Looks up the named containers through `filters`, keeping the order given. Containers that don't exist,
    /// or that `filters` hides (such as plugin-managed containers), are reported in `notFoundErrors`.
    func findContainers(
        named ids: [String],
        filters: ContainerListFilters
    ) async throws -> (found: [ContainerSnapshot], notFoundErrors: [any Error]) {
        // An empty ID filter matches every container, so there is nothing to look up.
        guard !ids.isEmpty else {
            return ([], [])
        }
        // Server `ids` filter is Id-only. Resolve Id or Name client-side (Name≠Id).
        // Prefer exact Id match over Name so a Name that equals another container's Id
        // cannot silently resolve to the wrong snapshot.
        let listed = try await list(filters: filters)
        var byId: [String: ContainerSnapshot] = [:]
        var byName: [String: [ContainerSnapshot]] = [:]
        for container in listed {
            byId[container.id] = container
            let name = container.configuration.name
            if !name.isEmpty {
                byName[name, default: []].append(container)
            }
        }

        var found: [ContainerSnapshot] = []
        var notFoundErrors: [any Error] = []
        for key in ids {
            if let snap = byId[key] {
                found.append(snap)
            } else if let named = byName[key] {
                if named.count == 1, let snap = named.first {
                    found.append(snap)
                } else {
                    notFoundErrors.append(
                        ContainerizationError(
                            .invalidArgument,
                            message:
                                "container name \(key) is ambiguous (\(named.count) matches); use a unique ID"
                        )
                    )
                }
            } else {
                notFoundErrors.append(
                    ContainerizationError(.notFound, message: "container with ID or name \(key) not found")
                )
            }
        }
        return (found, notFoundErrors)
    }

    /// Looks up a single container through `filters`, throwing a not-found error if it doesn't exist
    /// or `filters` hides it. Accepts stable Id or Name.
    func findContainer(id: String, filters: ContainerListFilters) async throws -> ContainerSnapshot {
        let (found, _) = try await findContainers(named: [id], filters: filters)
        guard let container = found.first else {
            throw ContainerizationError(.notFound, message: "container with ID or name \(id) not found")
        }
        return container
    }
}
