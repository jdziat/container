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
import Testing

@testable import container_compose

/// The destructive compose verbs (`rm`, `kill`, `down`, `up --force-recreate`, `--remove-orphans`,
/// `down -v`) must only ever act on resources carrying THIS project's compose label. They once
/// deleted any container that shared a service's name, and `--remove-orphans` compared UUIDs to
/// names and would have deleted the project's own containers. These tests are the only guard that
/// runs in the unit suite; the live harness covers the same paths but needs a running system.
struct ComposeScopeTests {
    private func container(id: String, name: String, labels: [String: String]) -> String {
        let l = labels.map { "\"\($0.key)\": \"\($0.value)\"" }.joined(separator: ",")
        return "{\"configuration\": {\"id\": \"\(id)\", \"name\": \"\(name)\", \"labels\": {\(l)}}}"
    }

    private func list(_ rows: [String]) -> String { "[" + rows.joined(separator: ",") + "]" }

    @Test func aForeignContainerSharingAServiceNameIsNeverOwned() throws {
        let json = list([
            container(id: "uuid-mine", name: "web", labels: ["com.docker.compose.project": "p"]),
            // Same name, different project (or none): must not be selected.
            container(id: "uuid-other-project", name: "web2", labels: ["com.docker.compose.project": "other"]),
            container(id: "uuid-unlabeled", name: "db", labels: [:]),
        ])
        let owned = try ComposeScope.ownedContainers(listJSON: json, project: "p")
        #expect(owned.map(\.name) == ["web"])
        #expect(owned.map(\.id) == ["uuid-mine"])
    }

    @Test func nameFallsBackToIdWhenAbsent() throws {
        let json = "[{\"configuration\": {\"id\": \"abc\", \"labels\": {\"com.docker.compose.project\": \"p\"}}}]"
        #expect(try ComposeScope.ownedContainers(listJSON: json, project: "p").first?.name == "abc")
    }

    @Test func unparseableListIsAnErrorNotAnEmptyScope() {
        // An error must propagate: treating garbage as "nothing owned" would let a caller fall
        // back to name-based deletion.
        #expect(throws: (any Error).self) { try ComposeScope.ownedContainers(listJSON: "not json", project: "p") }
        #expect(throws: (any Error).self) { try ComposeScope.orphanContainerIDs(listJSON: "{}", project: "p", declaredServices: []) }
    }

    @Test func orphansAreContainersOfUndeclaredServicesOnly() throws {
        let json = list([
            container(id: "keep-declared", name: "web", labels: ["com.docker.compose.project": "p", "com.docker.compose.service": "web"]),
            // Declared in the file but behind an inactive profile: NOT an orphan.
            container(id: "keep-profile", name: "tools", labels: ["com.docker.compose.project": "p", "com.docker.compose.service": "tools"]),
            container(id: "orphan", name: "ghost", labels: ["com.docker.compose.project": "p", "com.docker.compose.service": "ghost"]),
            // Another project's container of an undeclared service: never ours to delete.
            container(id: "foreign", name: "ghost2", labels: ["com.docker.compose.project": "other", "com.docker.compose.service": "ghost"]),
            // Project label but no service label: unknown, so left alone.
            container(id: "no-service", name: "odd", labels: ["com.docker.compose.project": "p"]),
        ])
        let orphans = try ComposeScope.orphanContainerIDs(listJSON: json, project: "p", declaredServices: ["web", "tools"])
        #expect(orphans == ["orphan"])
    }

    @Test func removeOrphansComparesServicesNotIds() throws {
        // The original bug compared container UUIDs to planned names, which never matched, so every
        // project container looked like an orphan. A UUID-named container of a declared service
        // must survive.
        let json = list([
            container(
                id: "8f3c2a10-1111-2222-3333-444455556666", name: "web",
                labels: ["com.docker.compose.project": "p", "com.docker.compose.service": "web"])
        ])
        #expect(try ComposeScope.orphanContainerIDs(listJSON: json, project: "p", declaredServices: ["web"]).isEmpty)
    }

    @Test func downVolumesRequireTheProjectLabelAndADeclaration() throws {
        let json = list([
            container(id: "v-mine", name: "p_data", labels: ["com.docker.compose.project": "p"]),
            // Declared name, but a foreign volume that merely shares it (no label).
            container(id: "v-foreign", name: "shared", labels: [:]),
            // Labeled for this project but not declared by the file (e.g. left by an older file).
            container(id: "v-stale", name: "p_old", labels: ["com.docker.compose.project": "p"]),
            container(id: "v-otherproj", name: "p_data2", labels: ["com.docker.compose.project": "other"]),
        ])
        let removable = try ComposeScope.removableVolumeNames(
            listJSON: json, project: "p", declared: ["p_data", "shared", "p_data2"])
        #expect(removable == ["p_data"])
    }
}
