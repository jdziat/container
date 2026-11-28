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

import Testing

@testable import ContainerAPIService

struct HostsMergeTests {
    @Test
    func unmarkedMergeKeepsSelfWhenOnlyPeerIPsAreManaged() {
        let existing = """
            127.0.0.1\tlocalhost
            192.168.64.10\tself-c
            192.168.64.11\tpeer-c
            """
        let managedBlock = """
            # BEGIN container-managed-peers
            192.168.64.11\tpeer-c
            # END container-managed-peers
            """
        let merged = ContainersService.mergeManagedPeersBlock(
            existing: existing,
            managedBlock: managedBlock,
            managedIPs: ["192.168.64.11"]
        )
        let lines = merged.split(separator: "\n").map(String.init)
        #expect(lines[0].contains("127.0.0.1"))
        #expect(lines[1].contains("192.168.64.10") && lines[1].contains("self-c"))
        #expect(lines.contains("# BEGIN container-managed-peers"))
        #expect(lines.contains("192.168.64.11\tpeer-c"))
    }

    @Test
    func unmarkedMergeDropsSelfWhenSelfIPIsMistakenlyManaged() {
        // Documents the failure mode: treating self as a managed peer IP removes
        // the bootstrap identity line before the marked block is appended.
        let existing = """
            127.0.0.1\tlocalhost
            192.168.64.10\tself-c
            """
        let managedBlock = """
            # BEGIN container-managed-peers
            192.168.64.11\tpeer-c
            # END container-managed-peers
            """
        let merged = ContainersService.mergeManagedPeersBlock(
            existing: existing,
            managedBlock: managedBlock,
            managedIPs: ["192.168.64.10", "192.168.64.11"]
        )
        let hostLines = merged.split(separator: "\n").map(String.init).filter {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && !t.hasPrefix("#")
        }
        #expect(hostLines[0].contains("127.0.0.1"))
        #expect(!hostLines[1].contains("self-c"))
        #expect(hostLines[1].contains("peer-c"))
    }
}
