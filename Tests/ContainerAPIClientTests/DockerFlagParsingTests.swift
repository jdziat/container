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

import ContainerizationError
import Foundation
import Testing

@testable import ContainerAPIClient

struct DockerFlagParsingTests {
    @Test func addHostAcceptsColonEqualsAndBracketedIPv6() throws {
        #expect(try Parser.extraHosts(["db:10.0.0.1"]) == ["db:10.0.0.1"])
        #expect(try Parser.extraHosts(["db=10.0.0.1"]) == ["db:10.0.0.1"])
        #expect(try Parser.extraHosts(["v6:[fd00::5]"]) == ["v6:fd00::5"])
        #expect(try Parser.extraHosts(["v6:fd00::5"]) == ["v6:fd00::5"])
        // Compose and Testcontainers service names routinely contain underscores.
        #expect(try Parser.extraHosts(["my_db:10.0.0.5", "_x:10.0.0.6"]) == ["my_db:10.0.0.5", "_x:10.0.0.6"])
    }

    @Test func addHostRejectsGarbage() {
        for bad in ["nocolon", ":1.2.3.4", "h:notanip", "h:999.1.1.1", "bad host:1.2.3.4", "h:host-gateway"] {
            #expect(throws: ContainerizationError.self, "\(bad)") { try Parser.extraHosts([bad]) }
        }
    }

    @Test func sysctlParsesAndNormalizesSlashes() throws {
        #expect(try Parser.sysctls(["net.ipv4.ip_forward=1"]) == ["net.ipv4.ip_forward": "1"])
        #expect(try Parser.sysctls(["net/ipv4/ip_forward=1"]) == ["net.ipv4.ip_forward": "1"])
        #expect(try Parser.sysctls(["kernel.msgmax=a=b"]) == ["kernel.msgmax": "a=b"])
    }

    @Test func sysctlRejectsMalformed() {
        for bad in ["novalue", "=1", "BAD KEY=1", "nodots=1", "Net.IPv4=1"] {
            #expect(throws: ContainerizationError.self, "\(bad)") { try Parser.sysctls([bad]) }
        }
    }

    @Test func stopSignalNormalizes() throws {
        #expect(try Parser.stopSignal("SIGTERM") == "SIGTERM")
        #expect(try Parser.stopSignal("term") == "SIGTERM")
        #expect(try Parser.stopSignal("int") == "SIGINT")
        #expect(try Parser.stopSignal("9") == "9")
    }

    @Test func stopSignalRejectsUnknown() {
        for bad in ["SIGNOPE", "0", "65", "", "TERMINATE"] {
            #expect(throws: ContainerizationError.self, "\(bad)") { try Parser.stopSignal(bad) }
        }
    }
}
