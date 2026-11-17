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

/// A peer on a shared network to inject into the guest `/etc/hosts`.
///
/// Packet 1 interim for Compose-style bare-name discovery (#1809): peers already running on a
/// shared network are written at bootstrap, and running peers are refreshed via `copyIn` when
/// containers join or leave so late joiners become reachable without a privileged DNS listener.
public struct PeerHostEntry: Codable, Sendable, Equatable {
    public let ipAddress: String
    public let hostnames: [String]

    public init(ipAddress: String, hostnames: [String]) {
        self.ipAddress = ipAddress
        self.hostnames = hostnames
    }

    /// Derive bare and qualified hostnames from an attachment hostname and its aliases.
    public static func hostnames(fromHostname hostname: String, aliases: [String] = []) -> [String] {
        var names: [String] = []
        var seen = Set<String>()
        func add(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard !trimmed.isEmpty else { return }
            let lower = trimmed.lowercased()
            if seen.insert(lower).inserted {
                names.append(lower)
            }
            if let bare = lower.split(separator: ".").first.map(String.init), bare != lower {
                if seen.insert(bare).inserted {
                    names.append(bare)
                }
            }
        }
        add(hostname)
        for alias in aliases where !alias.hasPrefix(".") {
            add(alias)
        }
        return names
    }
}
