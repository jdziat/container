//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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

import ContainerResource
import ContainerizationError
import DNSServer

/// Validates the DNS names that the network attachments of a new container claim.
///
/// Exact hostnames and aliases are unique **per network** (L3): the same name may appear on
/// different networks. Within one network, exact names must not collide across containers
/// (running or stopped). A subtree alias such as `.example.test` must be rooted at a name that
/// the same attachment owns.
enum AttachmentNameValidator {
    /// The most aliases that a single attachment may declare.
    static let maximumAliasesPerAttachment = AliasPolicy.maximumAliasesPerAttachment

    /// The fewest labels that an exact alias, or the base of a subtree alias, may have.
    static let minimumAliasLabels = AliasPolicy.minimumLabels

    /// Validates the attachments of a new container against the attachments of all existing containers.
    ///
    /// Names are compared case-insensitively and without a trailing dot, scoped by network id.
    ///
    /// - Parameters:
    ///   - networks: The attachments of the container being created.
    ///   - existing: The attachments of every existing container.
    /// - Throws: `ContainerizationError` with code `.exists` if a hostname or alias is already claimed
    ///   on the same network, and with code `.invalidArgument` if an alias is malformed or breaks a rule.
    static func validate(networks: [AttachmentConfiguration], existing: [AttachmentConfiguration]) throws {
        var claimedByNetwork: [String: Set<String>] = [:]
        for attachment in existing {
            var set = claimedByNetwork[attachment.network, default: []]
            set.insert(AttachmentOptions.canonicalHostname(attachment.options.hostname))
            for alias in attachment.options.aliases {
                set.insert(Self.canonicalAlias(alias))
            }
            claimedByNetwork[attachment.network] = set
        }

        var conflictingHostnames = [String]()
        for attachment in networks {
            let host = AttachmentOptions.canonicalHostname(attachment.options.hostname)
            // Exact-name uniqueness only. Subtree aliases in `claimed` are ignored here
            // because lookup prefers exact hostnames over subtrees (docs/networking.md);
            // a hostname under `.example.test` is therefore allowed. Alias ↔ subtree
            // coverage for *new* aliases is enforced in the alias loop below.
            let exactClaimed = claimedByNetwork[attachment.network, default: []].filter { entry in
                guard let rule = try? DNSMatchRule(entry) else { return true }
                if case .exact = rule { return true }
                return false
            }
            if exactClaimed.contains(host) {
                conflictingHostnames.append(attachment.options.hostname)
            }
        }
        guard conflictingHostnames.isEmpty else {
            throw ContainerizationError(
                .exists,
                message:
                    "hostname(s) already exist on the same network: \(conflictingHostnames). "
                    + "Exact hostnames and aliases are unique per network "
                    + "(stop the other container on that network, or pick a different name; see docs/docker-job-catalog.md)."
            )
        }

        // Hostnames of this container, keyed by network — an alias may reuse a name that this
        // container only uses as a hostname on a *different* network.
        var ownHostnamesByNetwork: [String: Set<String>] = [:]
        for attachment in networks {
            ownHostnamesByNetwork[attachment.network, default: []].insert(
                AttachmentOptions.canonicalHostname(attachment.options.hostname)
            )
        }

        var ownAliasesByNetwork: [String: Set<String>] = [:]
        var conflictingAliases = [String]()
        for attachment in networks {
            let aliases = attachment.options.aliases
            guard !aliases.isEmpty else {
                continue
            }

            let rules: [DNSMatchRule]
            do {
                let hostname: DNSName
                do {
                    hostname = try DNSName(AttachmentOptions.canonicalHostname(attachment.options.hostname))
                } catch {
                    throw ContainerizationError(
                        .invalidArgument,
                        message: "invalid hostname \"\(attachment.options.hostname)\": \(error)"
                    )
                }
                rules = try AliasPolicy.validate(aliases: aliases, hostname: hostname, network: attachment.network)
            } catch let violation as AliasPolicy.Violation {
                throw ContainerizationError(.invalidArgument, message: violation.description)
            }

            let claimed = claimedByNetwork[attachment.network, default: []]
            let ownHosts = ownHostnamesByNetwork[attachment.network, default: []]
            var ownAliases = ownAliasesByNetwork[attachment.network, default: []]

            for (alias, rule) in zip(aliases, rules) {
                let name = rule.description
                switch rule {
                case .exact:
                    guard !ownHosts.contains(name) else {
                        throw ContainerizationError(
                            .invalidArgument,
                            message: "alias \"\(alias)\" is already a hostname of the container on network \(attachment.network)"
                        )
                    }
                    guard ownAliases.insert(name).inserted else {
                        throw ContainerizationError(
                            .invalidArgument,
                            message: "alias \"\(alias)\" is declared more than once on network \(attachment.network)"
                        )
                    }
                    if Self.conflictsWithClaimed(rule: rule, claimed: claimed) {
                        conflictingAliases.append(alias)
                    }
                case .subtree:
                    guard ownAliases.insert(name).inserted else {
                        throw ContainerizationError(
                            .invalidArgument,
                            message: "alias \"\(alias)\" is declared more than once on network \(attachment.network)"
                        )
                    }
                    for host in ownHosts {
                        if let dns = try? DNSName(host), rule.matches(dns) {
                            throw ContainerizationError(
                                .invalidArgument,
                                message: "subtree alias \"\(alias)\" covers hostname \"\(host)\" of the container"
                            )
                        }
                    }
                    if Self.conflictsWithClaimed(rule: rule, claimed: claimed) {
                        conflictingAliases.append(alias)
                    }
                }
            }
            ownAliasesByNetwork[attachment.network] = ownAliases
        }
        guard conflictingAliases.isEmpty else {
            throw ContainerizationError(
                .exists,
                message:
                    "alias(es) already exist on the same network: \(conflictingAliases). "
                    + "Exact DNS aliases are unique per network — two containers on one network cannot "
                    + "both publish the same alias. The same alias on different networks is allowed "
                    + "(see docs/docker-job-catalog.md)."
            )
        }
    }

    /// Validates the attachments of a container that was read back from storage.
    ///
    /// The stored configuration is not trusted to be what `validate` accepted when the container was
    /// created, since the file can be damaged or edited. This checks every rule that does not depend on
    /// other containers (`existing` is intentionally empty), so a stored container with bad names fails
    /// to start with an explanation. Peer uniqueness is enforced again at create/connect time.
    ///
    /// - Throws: `ContainerizationError` with code `.invalidState` if the stored names break a rule.
    static func validateStored(id: String, networks: [AttachmentConfiguration]) throws {
        do {
            try validate(networks: networks, existing: [])
        } catch {
            throw ContainerizationError(
                .invalidState,
                message: "the stored configuration of container \(id) has invalid network names: \(error)"
            )
        }
    }

    /// Normalize an alias from an already-stored container for comparison.
    /// Prefer `DNSMatchRule` when the alias still parses; otherwise fall back to
    /// hostname canonicalization so a damaged stored config cannot crash validation.
    private static func canonicalAlias(_ alias: String) -> String {
        guard let rule = try? DNSMatchRule(alias) else {
            return AttachmentOptions.canonicalHostname(alias)
        }
        return rule.description
    }

    /// True when `rule` collides with a claimed hostname/alias, including subtree coverage.
    private static func conflictsWithClaimed(rule: DNSMatchRule, claimed: Set<String>) -> Bool {
        if claimed.contains(rule.description) {
            return true
        }
        for entry in claimed {
            if let other = try? DNSMatchRule(entry) {
                switch (rule, other) {
                case (.exact(let name), .subtree):
                    if other.matches(name) { return true }
                case (.subtree, .exact(let name)):
                    if rule.matches(name) { return true }
                case (.subtree(let a), .subtree(let b)):
                    // Same base only. Nested subtrees (`.apps.gateway` under `.gateway`)
                    // are allowed when each container owns its own base (see tests).
                    if a == b { return true }
                case (.exact(let a), .exact(let b)):
                    if a == b { return true }
                }
            } else if let host = try? DNSName(entry), rule.matches(host) {
                return true
            }
        }
        return false
    }
}
