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

struct RestartPolicyTests {
    @Test(
        "parse accepts every policy name",
        arguments: [
            ("no", RestartPolicy.no),
            ("on-failure", .onFailure),
            ("always", .always),
            ("unless-stopped", .unlessStopped),
        ])
    func parseValidNames(raw: String, expected: RestartPolicy) throws {
        #expect(try RestartPolicy.parse(raw) == expected)
    }

    @Test(
        "parse normalizes case and whitespace",
        arguments: [
            ("ALWAYS", RestartPolicy.always),
            ("  unless-stopped\n", .unlessStopped),
            ("On-Failure", .onFailure),
        ])
    func parseNormalizes(raw: String, expected: RestartPolicy) throws {
        #expect(try RestartPolicy.parse(raw) == expected)
    }

    @Test("parseDetailed accepts on-failure max retries")
    func parseOnFailureMaxRetries() throws {
        let parsed = try RestartPolicy.parseDetailed("on-failure:5")
        #expect(parsed.policy == .onFailure)
        #expect(parsed.maximumRetryCount == 5)

        let unlimited = try RestartPolicy.parseDetailed("on-failure")
        #expect(unlimited.policy == .onFailure)
        #expect(unlimited.maximumRetryCount == nil)

        let zero = try RestartPolicy.parseDetailed("on-failure:0")
        #expect(zero.policy == .onFailure)
        #expect(zero.maximumRetryCount == 0)
    }

    @Test("parse rejects unknown policies and invalid suffixes", arguments: ["", "onfailure", "sometimes", ":5", "always:5", "on-failure:abc"])
    func parseInvalid(raw: String) {
        #expect(throws: RestartPolicyError.invalid(raw)) {
            try RestartPolicy.parse(raw)
        }
    }

    @Test("invalid policy error lists the accepted values")
    func invalidErrorDescription() {
        let description = RestartPolicyError.invalid("bogus").description
        #expect(description.contains("\"bogus\""))
        for policy in RestartPolicy.allCases {
            #expect(description.contains(policy.rawValue))
        }
        #expect(description.contains("on-failure:<max>"))
    }

    @Test(
        "shouldRestartOnExit follows the policy for a process that exited on its own",
        arguments: [
            (RestartPolicy.no, Int32(0), false),
            (.no, 1, false),
            (.onFailure, 0, false),
            (.onFailure, 1, true),
            (.onFailure, 137, true),
            (.always, 0, true),
            (.always, 1, true),
            (.unlessStopped, 0, true),
            (.unlessStopped, 1, true),
        ])
    func restartOnExit(policy: RestartPolicy, exitCode: Int32, expected: Bool) {
        #expect(policy.shouldRestartOnExit(exitCode: exitCode, manuallyStopped: false) == expected)
    }

    @Test("on-failure respects maximumRetryCount")
    func onFailureMaxRetries() {
        let policy = RestartPolicy.onFailure
        #expect(policy.shouldRestartOnExit(exitCode: 1, manuallyStopped: false, failureCount: 0, maximumRetryCount: 3))
        #expect(policy.shouldRestartOnExit(exitCode: 1, manuallyStopped: false, failureCount: 2, maximumRetryCount: 3))
        #expect(!policy.shouldRestartOnExit(exitCode: 1, manuallyStopped: false, failureCount: 3, maximumRetryCount: 3))
        #expect(!policy.shouldRestartOnExit(exitCode: 1, manuallyStopped: false, failureCount: 0, maximumRetryCount: 0))
        #expect(policy.shouldRestartOnExit(exitCode: 1, manuallyStopped: false, failureCount: 100, maximumRetryCount: nil))
    }

    @Test("a manual stop suppresses restart for every policy", arguments: RestartPolicy.allCases)
    func manualStopSuppressesRestart(policy: RestartPolicy) {
        #expect(!policy.shouldRestartOnExit(exitCode: 1, manuallyStopped: true))
        #expect(!policy.shouldRestartOnExit(exitCode: 0, manuallyStopped: true))
    }

    @Test(
        "shouldStartOnBoot follows the policy and the manual-stop marker",
        arguments: [
            (RestartPolicy.no, false, false),
            (.no, true, false),
            (.onFailure, false, false),
            (.onFailure, true, false),
            (.always, false, true),
            (.always, true, true),
            (.unlessStopped, false, true),
            (.unlessStopped, true, false),
        ])
    func startOnBoot(policy: RestartPolicy, manuallyStopped: Bool, expected: Bool) {
        #expect(policy.shouldStartOnBoot(manuallyStopped: manuallyStopped) == expected)
    }

    @Test("backoff doubles from 250ms on attempt 1 and caps at 60s")
    func backoffDelay() {
        #expect(RestartPolicy.backoffDelayMilliseconds(attempt: 1) == 250)
        #expect(RestartPolicy.backoffDelayMilliseconds(attempt: 2) == 500)
        #expect(RestartPolicy.backoffDelayMilliseconds(attempt: 3) == 1000)
        #expect(RestartPolicy.backoffDelayMilliseconds(attempt: 9) == 60_000)
        #expect(RestartPolicy.backoffDelayMilliseconds(attempt: 20) == 60_000)
        #expect(RestartPolicy.backoffDelayMilliseconds(attempt: 0) == 250)
    }

    @Test("Policies encode as their Docker-compatible names")
    func encodedNames() throws {
        let encoder = JSONEncoder()
        for policy in RestartPolicy.allCases {
            let data = try encoder.encode(policy)
            #expect(String(data: data, encoding: .utf8) == "\"\(policy.rawValue)\"")
        }
    }

    @Test("Policies round trip through JSON", arguments: RestartPolicy.allCases)
    func roundTrip(policy: RestartPolicy) throws {
        let data = try JSONEncoder().encode([policy])
        #expect(try JSONDecoder().decode([RestartPolicy].self, from: data) == [policy])
    }

    @Test("Decoding an unknown policy name fails")
    func decodeUnknown() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(RestartPolicy.self, from: Data("\"sometimes\"".utf8))
        }
    }
}
