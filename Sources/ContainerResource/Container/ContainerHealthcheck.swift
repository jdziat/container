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

/// Create-time healthcheck contract for a container (Docker HEALTHCHECK / compose healthcheck).
public struct ContainerHealthcheck: Sendable, Codable, Equatable {
    /// Probe command as argv (for example `["CMD", "curl", "-f", "http://localhost/"]`).
    public var test: [String]
    /// Seconds between probes after the container starts.
    public var intervalSeconds: UInt64
    /// Seconds to wait for a single probe before treating it as failed.
    public var timeoutSeconds: UInt64
    /// Seconds to wait after start before the first probe.
    public var startPeriodSeconds: UInt64
    /// Consecutive failures before the container is marked unhealthy.
    public var retries: UInt64

    public init(
        test: [String],
        intervalSeconds: UInt64 = 30,
        timeoutSeconds: UInt64 = 30,
        startPeriodSeconds: UInt64 = 0,
        retries: UInt64 = 3
    ) {
        self.test = test
        self.intervalSeconds = intervalSeconds
        self.timeoutSeconds = timeoutSeconds
        self.startPeriodSeconds = startPeriodSeconds
        self.retries = retries
    }

    /// Whether this contract disables probing (`NONE` / empty).
    public var isDisabled: Bool {
        guard let first = test.first else { return true }
        return first.uppercased() == "NONE"
    }

    /// Executable and argv for a guest probe process.
    ///
    /// - `CMD` / bare argv → run the binary directly
    /// - `CMD-SHELL` → `/bin/sh -c <command>`
    public func resolvedCommand() throws -> (executable: String, arguments: [String]) {
        guard !isDisabled else {
            throw ContainerHealthcheckError.disabled
        }
        guard let kind = test.first else {
            throw ContainerHealthcheckError.invalidTest(test)
        }
        switch kind.uppercased() {
        case "CMD":
            let argv = Array(test.dropFirst())
            guard let executable = argv.first else {
                throw ContainerHealthcheckError.invalidTest(test)
            }
            return (executable, Array(argv.dropFirst()))
        case "CMD-SHELL":
            guard test.count >= 2 else {
                throw ContainerHealthcheckError.invalidTest(test)
            }
            let shellCommand = test.dropFirst().joined(separator: " ")
            return ("/bin/sh", ["-c", shellCommand])
        default:
            // Bare argv without a CMD/CMD-SHELL prefix.
            return (kind, Array(test.dropFirst()))
        }
    }
}

public enum ContainerHealthcheckError: Error, Equatable, CustomStringConvertible {
    case disabled
    case invalidTest([String])

    public var description: String {
        switch self {
        case .disabled:
            return "healthcheck is disabled (NONE)"
        case .invalidTest(let test):
            return "invalid healthcheck test \(test)"
        }
    }
}

/// Observed health status exposed via inspect (probe execution may update this at runtime).
public enum ContainerHealthStatus: String, Sendable, Codable, Equatable {
    case none
    case starting
    case healthy
    case unhealthy
}
