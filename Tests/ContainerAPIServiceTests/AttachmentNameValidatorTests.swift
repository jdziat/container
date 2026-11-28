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

import ContainerResource
import ContainerizationError
import Testing

@testable import ContainerAPIService

struct AttachmentNameValidatorTests {
    private func attachment(_ hostname: String, network: String = "default", aliases: [String] = []) -> AttachmentConfiguration {
        AttachmentConfiguration(network: network, options: AttachmentOptions(hostname: hostname, aliases: aliases))
    }

    private func validate(_ networks: [AttachmentConfiguration], existing: [AttachmentConfiguration] = []) throws {
        try AttachmentNameValidator.validate(networks: networks, existing: existing)
    }

    private func expectError(_ code: ContainerizationError.Code, containing text: String? = nil, _ body: () throws -> Void) {
        do {
            try body()
            Issue.record("expected a \(code) error")
        } catch let error as ContainerizationError {
            #expect(error.code == code, "unexpected error: \(error)")
            if let text {
                #expect("\(error)".contains(text), "unexpected error: \(error)")
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    // MARK: - Hostnames

    @Test("Attachments without aliases and without conflicts are accepted")
    func noAliases() throws {
        try validate([attachment("foo.test.")], existing: [attachment("bar.test.")])
    }

    @Test("A hostname that an existing container uses on the same network is rejected")
    func hostnameConflict() {
        expectError(.exists, containing: "unique per network") {
            try validate([attachment("foo.test.")], existing: [attachment("foo.test.")])
        }
    }

    @Test("The same hostname on different networks is accepted")
    func hostnameOnDifferentNetworks() throws {
        try validate(
            [attachment("foo.test.", network: "a")],
            existing: [attachment("foo.test.", network: "b")]
        )
    }

    @Test("Hostnames are compared without regard to case or a trailing dot")
    func hostnameConflictNormalized() {
        expectError(.exists) {
            try validate([attachment("Foo.Test.")], existing: [attachment("foo.test")])
        }
    }

    @Test("A hostname that an existing container has as an exact alias on the same network is rejected")
    func hostnameConflictsWithAlias() {
        expectError(.exists, containing: "unique per network") {
            try validate(
                [attachment("api.test.")],
                existing: [attachment("foo.test.", aliases: ["api.test"])]
            )
        }
    }

    @Test("A hostname may match an alias that exists only on another network")
    func hostnameMatchesAliasOnOtherNetwork() throws {
        try validate(
            [attachment("api.test.", network: "a")],
            existing: [attachment("foo.test.", network: "b", aliases: ["api.test"])]
        )
    }

    @Test("A hostname below an existing subtree alias is accepted")
    func hostnameBelowSubtree() throws {
        try validate(
            [attachment("web.foo.test.")],
            existing: [attachment("foo.test.", aliases: [".foo.test"])]
        )
    }

    @Test("An invalid hostname with aliases is rejected")
    func invalidHostnameWithAliases() {
        expectError(.invalidArgument, containing: "invalid hostname") {
            try validate([attachment("not a hostname", aliases: ["api.test"])])
        }
    }

    @Test("A subtree alias may cover this container's hostname on a different network")
    func subtreeCoversOwnHostnameOnOtherNetwork() throws {
        try validate([
            attachment("web.example.com", network: "a"),
            attachment("example.com", network: "b", aliases: [".example.com"]),
        ])
    }

    @Test("A subtree alias that covers another hostname of the same container on the same network is rejected")
    func subtreeCoversOwnHostnameSameNetwork() {
        expectError(.invalidArgument, containing: "covers hostname") {
            try validate([
                attachment("web.example.com", network: "edge"),
                attachment("example.com", network: "edge", aliases: [".example.com"]),
            ])
        }
    }

    // MARK: - Exact aliases

    @Test("An exact alias that nothing else claims is accepted")
    func exactAlias() throws {
        try validate(
            [attachment("foo.test.", aliases: ["api.test", "Other.Test."])],
            existing: [attachment("bar.test.")]
        )
    }

    @Test("An exact alias that matches an existing hostname on the same network is rejected")
    func aliasConflictsWithHostname() {
        expectError(.exists, containing: "unique per network") {
            try validate(
                [attachment("foo.test.", aliases: ["bar.test"])],
                existing: [attachment("bar.test.")]
            )
        }
    }

    @Test("An exact alias that matches an existing alias on the same network is rejected")
    func aliasConflictsWithAlias() {
        expectError(.exists, containing: "unique per network") {
            try validate(
                [attachment("foo.test.", aliases: ["API.test."])],
                existing: [attachment("bar.test.", aliases: ["api.test"])]
            )
        }
    }

    @Test("An exact alias that matches the container's own hostname is rejected")
    func aliasMatchesOwnHostname() {
        expectError(.invalidArgument, containing: "already a hostname") {
            try validate([attachment("foo.test.", aliases: ["foo.test"])])
        }
    }

    @Test("An exact alias may match this container's hostname on a different network")
    func aliasMatchesOtherOwnHostnameOnOtherNetwork() throws {
        try validate([
            attachment("foo.test.", aliases: ["bar.test"]),
            attachment("bar.test", network: "other"),
        ])
    }

    @Test("The same exact alias on two networks is accepted (network-scoped)")
    func aliasOnTwoNetworks() throws {
        try validate([
            attachment("foo.test.", aliases: ["api.test"]),
            attachment("foo", network: "other", aliases: ["api.test"]),
        ])
    }

    @Test("The same exact alias reused by another container on a different network is accepted")
    func aliasReuseAcrossNetworks() throws {
        try validate(
            [attachment("foo.test.", network: "a", aliases: ["redis"])],
            existing: [attachment("bar.test.", network: "b", aliases: ["redis"])]
        )
    }

    @Test("An exact alias with a single label is accepted", arguments: ["api", "API.", "redis"])
    func unqualifiedExactAlias(alias: String) throws {
        try validate([attachment("foo.test.", aliases: [alias])])
    }

    @Test("Reserved single-label aliases are rejected", arguments: ["localhost", "LOCALHOST.", "localdomain"])
    func reservedExactAlias(alias: String) {
        expectError(.invalidArgument, containing: "reserved") {
            try validate([attachment("foo.test.", aliases: [alias])])
        }
    }

    @Test("An exact alias with two labels is accepted")
    func qualifiedExactAlias() throws {
        try validate([attachment("foo.test.", aliases: ["api.test"])])
    }

    @Test("An alias listed twice is rejected")
    func duplicateAlias() {
        expectError(.invalidArgument, containing: "more than once") {
            try validate([attachment("foo.test.", aliases: ["api.test", "API.test."])])
        }
    }

    // MARK: - Malformed aliases and limits

    @Test("Malformed aliases are rejected", arguments: ["", ".", "..", "exa mple.test", "-bad.test", "a..b"])
    func malformedAlias(alias: String) {
        expectError(.invalidArgument, containing: "invalid alias") {
            try validate([attachment("foo.test.", aliases: [alias])])
        }
    }

    @Test("An asterisk is rejected with a hint about the leading dot")
    func asterisk() {
        expectError(.invalidArgument, containing: "leading dot") {
            try validate([attachment("foo.test.", aliases: ["*.foo.test"])])
        }
    }

    @Test("The alias limit is enforced per attachment")
    func aliasLimit() throws {
        let limit = AttachmentNameValidator.maximumAliasesPerAttachment
        let atLimit = (0..<limit).map { "alias\($0).test" }
        try validate([attachment("foo.test.", aliases: atLimit)])

        expectError(.invalidArgument, containing: "at most") {
            try validate([attachment("foo.test.", aliases: atLimit + ["one-more.test"])])
        }
    }

    // MARK: - Subtree aliases

    @Test("A subtree alias below the attachment's hostname is accepted")
    func subtreeBelowHostname() throws {
        try validate([attachment("gateway.test.", aliases: [".gateway.test"])])
    }

    @Test("A subtree alias below an exact alias of the attachment is accepted")
    func subtreeBelowAlias() throws {
        try validate([attachment("foo.test.", aliases: ["apps.test", ".apps.test"])])
    }

    @Test("A subtree alias below a name the attachment does not own is rejected")
    func subtreeNotOwned() {
        expectError(.invalidArgument, containing: "neither") {
            try validate([attachment("foo.test.", aliases: [".apps.test"])])
        }
    }

    @Test("A subtree alias below another container's hostname is rejected")
    func subtreeBelowOtherContainer() {
        expectError(.invalidArgument, containing: "neither") {
            try validate(
                [attachment("foo.test.", aliases: [".gateway.test"])],
                existing: [attachment("gateway.test.")]
            )
        }
    }

    @Test("A subtree alias below another attachment's hostname is rejected")
    func subtreeBelowOtherAttachment() {
        expectError(.invalidArgument, containing: "neither") {
            try validate([
                attachment("foo.test.", aliases: [".bar.test"]),
                attachment("bar.test", network: "other"),
            ])
        }
    }

    @Test("A subtree alias whose base has a single label is rejected even when the container owns it")
    func subtreeSingleLabelBase() {
        expectError(.invalidArgument, containing: "at least 2 labels") {
            try validate([attachment("test", aliases: [".test"])])
        }
    }

    @Test("A subtree alias is compared to the hostname without regard to case or a trailing dot")
    func subtreeNormalized() throws {
        try validate([attachment("Gateway.Test.", aliases: [".GATEWAY.test."])])
    }

    @Test("Two containers on the same network cannot both own the same subtree base")
    func subtreeCannotBeShared() {
        expectError(.exists, containing: "unique per network") {
            try validate(
                [attachment("gateway.test.", aliases: [".gateway.test"])],
                existing: [attachment("gateway.test.", aliases: [".gateway.test"])]
            )
        }
    }

    @Test("Nested subtrees rooted at names their own containers own are accepted")
    func nestedSubtrees() throws {
        try validate(
            [attachment("apps.gateway.test.", aliases: [".apps.gateway.test"])],
            existing: [attachment("gateway.test.", aliases: [".gateway.test"])]
        )
    }

    @Test("Stopped and running containers are treated alike because the caller passes all of them")
    func existingIncludesEveryContainer() {
        expectError(.exists) {
            try validate(
                [attachment("foo.test.", aliases: ["api.test"])],
                existing: [attachment("a.test."), attachment("b.test.", aliases: ["api.test"])]
            )
        }
    }

    // MARK: - Stored configurations

    @Test("A stored configuration that follows the rules is accepted")
    func storedValid() throws {
        try AttachmentNameValidator.validateStored(
            id: "gateway",
            networks: [attachment("gateway.test.", aliases: ["api.test", ".gateway.test"])]
        )
    }

    @Test("A stored configuration without aliases is accepted")
    func storedWithoutAliases() throws {
        try AttachmentNameValidator.validateStored(id: "foo", networks: [attachment("foo.test.")])
    }

    @Test("A stored subtree alias below a name the attachment does not own is rejected")
    func storedUnownedSubtree() {
        expectError(.invalidState, containing: "container victim") {
            try AttachmentNameValidator.validateStored(
                id: "victim",
                networks: [attachment("victim.test.", aliases: [".com.example"])]
            )
        }
    }

    @Test("A stored alias that is not a valid rule is rejected and the error names the container")
    func storedMalformed() {
        expectError(.invalidState, containing: "invalid alias") {
            try AttachmentNameValidator.validateStored(
                id: "victim",
                networks: [attachment("victim.test.", aliases: ["*.victim.test"])]
            )
        }
    }

    @Test("A stored configuration with too many aliases is rejected")
    func storedTooMany() {
        let aliases = (0...AttachmentNameValidator.maximumAliasesPerAttachment).map { "alias\($0).test" }
        expectError(.invalidState, containing: "at most") {
            try AttachmentNameValidator.validateStored(id: "victim", networks: [attachment("victim.test.", aliases: aliases)])
        }
    }

    @Test("A stored alias may match this container's hostname on a different network")
    func storedAliasIsHostnameOnOtherNetwork() throws {
        try AttachmentNameValidator.validateStored(
            id: "victim",
            networks: [
                attachment("victim.test.", aliases: ["db.test"]),
                attachment("db.test", network: "other"),
            ]
        )
    }

    @Test("A stored alias that matches a hostname on the same network is rejected")
    func storedAliasIsHostnameSameNetwork() {
        expectError(.invalidState, containing: "already a hostname") {
            try AttachmentNameValidator.validateStored(
                id: "victim",
                networks: [
                    attachment("victim.test.", network: "edge", aliases: ["db.test"]),
                    attachment("db.test", network: "edge"),
                ]
            )
        }
    }
}
