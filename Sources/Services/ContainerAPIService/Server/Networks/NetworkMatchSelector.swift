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

import ContainerNetworkClient

/// Chooses the best answer to a name from the matches that individual networks report.
///
/// Exact hostnames and aliases are unique **per network** (L3), so the same name may exist on
/// more than one network. Preference within a cross-network scan: hostname, then exact alias,
/// then the subtree alias with the longest base. When two networks offer the same kind, the
/// first reported wins — callers should pass sources in a stable order (e.g. sorted network
/// ids) so ties are deterministic. Guests normally query DNS for a single attached network;
/// this aggregator is for host-side lookups across all networks.
struct NetworkMatchSelector {
    /// The best match offered so far.
    private(set) var best: NetworkMatch?

    /// Considers a match reported by a network.
    ///
    /// - Returns: always `false` so the caller scans every network (names are not globally unique).
    @discardableResult
    mutating func offer(_ match: NetworkMatch) -> Bool {
        switch match.kind {
        case .hostname:
            switch best?.kind {
            case .hostname?:
                break
            default:
                best = match
            }
        case .alias:
            switch best?.kind {
            case .hostname?, .alias?:
                break
            default:
                best = match
            }
        case .subtree(let baseLabelCount):
            switch best?.kind {
            case .hostname?, .alias?:
                break
            case .subtree(let bestBaseLabelCount)?:
                if baseLabelCount > bestBaseLabelCount {
                    best = match
                }
            case nil:
                best = match
            }
        }
        return false
    }
}

extension NetworkMatchSelector {
    /// Looks the name up on each source, and returns the best match.
    ///
    /// Every source is asked. A source that throws is skipped, and reported to `onFailure`. A network
    /// whose helper is starting up or shutting down cannot answer, and it should not make the answers
    /// of the other networks fail.
    ///
    /// - Parameters:
    ///   - sources: The networks to ask, each with a name for reporting and a function that does the lookup.
    ///   - onFailure: Called with the name of a source and the error when a source throws.
    static func select(
        from sources: [(name: String, lookup: @Sendable () async throws -> NetworkMatch?)],
        onFailure: @Sendable (String, any Error) -> Void
    ) async -> NetworkMatch? {
        var selector = NetworkMatchSelector()
        for source in sources {
            let match: NetworkMatch?
            do {
                match = try await source.lookup()
            } catch {
                onFailure(source.name, error)
                continue
            }
            if let match, selector.offer(match) {
                break
            }
        }
        return selector.best
    }
}
