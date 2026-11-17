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

/// Docker/Podman-compatible container restart policy.
public enum RestartPolicy: String, Sendable, Codable, CaseIterable {
    /// Never restart the container.
    case no
    /// Restart when the container exits with a non-zero status.
    case onFailure = "on-failure"
    /// Always restart on exit, and start again when the API server boots.
    case always
    /// Like `always`, but do not start on API server boot if the container was
    /// last stopped intentionally via `container stop`.
    case unlessStopped = "unless-stopped"

    /// Whether a process exit with the given status should trigger a restart.
    ///
    /// - Parameters:
    ///   - exitCode: Process exit status.
    ///   - manuallyStopped: Whether the user intentionally stopped the container.
    ///   - failureCount: How many failure restarts have already been performed.
    ///   - maximumRetryCount: Cap for `on-failure` (nil = unlimited). Ignored for other policies.
    public func shouldRestartOnExit(
        exitCode: Int32,
        manuallyStopped: Bool,
        failureCount: UInt64 = 0,
        maximumRetryCount: UInt64? = nil
    ) -> Bool {
        if manuallyStopped {
            return false
        }
        switch self {
        case .no:
            return false
        case .onFailure:
            guard exitCode != 0 else { return false }
            if let maximumRetryCount, failureCount >= maximumRetryCount {
                return false
            }
            return true
        case .always, .unlessStopped:
            return true
        }
    }

    /// Whether `container system start` / API server boot should start this container.
    public func shouldStartOnBoot(manuallyStopped: Bool) -> Bool {
        switch self {
        case .no, .onFailure:
            return false
        case .always:
            return true
        case .unlessStopped:
            return !manuallyStopped
        }
    }

    /// Delay before crash restart attempt `attempt` (1-based; exponential, capped at 60s).
    ///
    /// Attempt 1 waits 250ms, attempt 2 waits 500ms, and so on. Passing the post-increment
    /// restart count keeps the first crash from using a "zero prior failures" delay slot.
    public static func backoffDelayMilliseconds(attempt: UInt64) -> UInt64 {
        let zeroBased = attempt > 0 ? attempt &- 1 : 0
        let shift = min(zeroBased, 8)
        let delay = 250 &* (1 &<< shift)
        return min(delay, 60_000)
    }

    /// Parsed `--restart` value, including optional `on-failure` max retries.
    public struct Parsed: Sendable, Equatable {
        public var policy: RestartPolicy
        /// Maximum failure restarts for `on-failure` (`nil` = unlimited).
        public var maximumRetryCount: UInt64?

        public init(policy: RestartPolicy, maximumRetryCount: UInt64? = nil) {
            self.policy = policy
            self.maximumRetryCount = maximumRetryCount
        }
    }

    public static func parse(_ raw: String) throws -> RestartPolicy {
        try parseDetailed(raw).policy
    }

    public static func parseDetailed(_ raw: String) throws -> Parsed {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = normalized.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let name = parts.isEmpty ? "" : String(parts[0])
        guard let policy = RestartPolicy(rawValue: name) else {
            throw RestartPolicyError.invalid(raw)
        }
        guard parts.count == 2 else {
            return Parsed(policy: policy, maximumRetryCount: nil)
        }
        guard policy == .onFailure else {
            throw RestartPolicyError.invalid(raw)
        }
        let retryRaw = String(parts[1])
        guard let retries = UInt64(retryRaw) else {
            throw RestartPolicyError.invalid(raw)
        }
        return Parsed(policy: policy, maximumRetryCount: retries)
    }
}

public enum RestartPolicyError: Error, CustomStringConvertible, Equatable {
    case invalid(String)

    public var description: String {
        switch self {
        case .invalid(let value):
            return "invalid restart policy \"\(value)\": expected no, on-failure, on-failure:<max>, always, or unless-stopped"
        }
    }
}
