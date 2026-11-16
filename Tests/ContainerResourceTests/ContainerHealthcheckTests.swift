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

@testable import ContainerResource

struct ContainerHealthcheckTests {
    @Test("Defaults match Docker's HEALTHCHECK defaults")
    func defaults() {
        let healthcheck = ContainerHealthcheck(test: ["CMD", "true"])
        #expect(healthcheck.test == ["CMD", "true"])
        #expect(healthcheck.intervalSeconds == 30)
        #expect(healthcheck.timeoutSeconds == 30)
        #expect(healthcheck.startPeriodSeconds == 0)
        #expect(healthcheck.retries == 3)
    }

    @Test("A healthcheck round trips through JSON")
    func roundTrip() throws {
        let original = ContainerHealthcheck(
            test: ["CMD", "curl", "-f", "http://localhost/"],
            intervalSeconds: 5,
            timeoutSeconds: 2,
            startPeriodSeconds: 10,
            retries: 7
        )
        let decoded = try JSONDecoder().decode(ContainerHealthcheck.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }

    @Test("An empty probe command round trips")
    func emptyTestRoundTrip() throws {
        let original = ContainerHealthcheck(test: [])
        let decoded = try JSONDecoder().decode(ContainerHealthcheck.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
        #expect(decoded.test.isEmpty)
    }

    @Test("Healthchecks that differ in any field are not equal")
    func inequality() {
        let base = ContainerHealthcheck(test: ["CMD", "true"])
        #expect(base == ContainerHealthcheck(test: ["CMD", "true"]))
        #expect(base != ContainerHealthcheck(test: ["CMD", "false"]))
        #expect(base != ContainerHealthcheck(test: ["CMD", "true"], intervalSeconds: 1))
        #expect(base != ContainerHealthcheck(test: ["CMD", "true"], timeoutSeconds: 1))
        #expect(base != ContainerHealthcheck(test: ["CMD", "true"], startPeriodSeconds: 1))
        #expect(base != ContainerHealthcheck(test: ["CMD", "true"], retries: 1))
    }

    @Test("Decoding fails when the probe command is missing")
    func decodeMissingTest() {
        let json = #"{"intervalSeconds":5,"timeoutSeconds":2,"startPeriodSeconds":0,"retries":3}"#
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ContainerHealthcheck.self, from: Data(json.utf8))
        }
    }

    @Test(
        "Health status raw values are stable",
        arguments: [
            (ContainerHealthStatus.none, "none"),
            (.starting, "starting"),
            (.healthy, "healthy"),
            (.unhealthy, "unhealthy"),
        ])
    func healthStatusRawValues(status: ContainerHealthStatus, raw: String) throws {
        #expect(status.rawValue == raw)
        let decoded = try JSONDecoder().decode([ContainerHealthStatus].self, from: JSONEncoder().encode([status]))
        #expect(decoded == [status])
    }

    @Test("NONE and empty tests are disabled")
    func disabled() {
        #expect(ContainerHealthcheck(test: []).isDisabled)
        #expect(ContainerHealthcheck(test: ["NONE"]).isDisabled)
        #expect(ContainerHealthcheck(test: ["none"]).isDisabled)
        #expect(!ContainerHealthcheck(test: ["CMD", "true"]).isDisabled)
    }

    @Test("resolvedCommand maps CMD and CMD-SHELL")
    func resolvedCommand() throws {
        let cmd = try ContainerHealthcheck(test: ["CMD", "curl", "-f", "http://localhost/"]).resolvedCommand()
        #expect(cmd.executable == "curl")
        #expect(cmd.arguments == ["-f", "http://localhost/"])

        let shell = try ContainerHealthcheck(test: ["CMD-SHELL", "curl -f http://localhost/ || exit 1"]).resolvedCommand()
        #expect(shell.executable == "/bin/sh")
        #expect(shell.arguments == ["-c", "curl -f http://localhost/ || exit 1"])

        let bare = try ContainerHealthcheck(test: ["/usr/bin/true"]).resolvedCommand()
        #expect(bare.executable == "/usr/bin/true")
        #expect(bare.arguments.isEmpty)
    }

    @Test("resolvedCommand rejects NONE and empty CMD")
    func resolvedCommandInvalid() {
        #expect(throws: ContainerHealthcheckError.disabled) {
            try ContainerHealthcheck(test: ["NONE"]).resolvedCommand()
        }
        #expect(throws: ContainerHealthcheckError.invalidTest(["CMD"])) {
            try ContainerHealthcheck(test: ["CMD"]).resolvedCommand()
        }
    }
}
