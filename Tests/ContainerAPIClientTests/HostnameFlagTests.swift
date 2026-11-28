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

@testable import ContainerAPIClient

struct HostnameFlagTests {
    @Test func testManagementHostname() throws {
        let m = try Flags.Management.parse(["--hostname", "myuts", "--name", "hn2"])
        #expect(m.hostname == "myuts")
        #expect(m.name == "hn2")
    }

    @Test func testManagementDomainname() throws {
        let m = try Flags.Management.parse(["--domainname", "example.test", "--name", "dn1"])
        #expect(m.domainname == "example.test")
        #expect(m.name == "dn1")
    }
}
