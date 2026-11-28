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

@testable import container_compose

struct ComposeNetworkTests {
    private func parse(_ value: Any, key: String = "front") throws -> ComposeNetworkParser.Parsed {
        try ComposeNetworkParser.parse(key: key, value: value, project: "proj")
    }

    @Test func aCreatedNetworkIsPrefixedWithTheProjectUnlessNamed() throws {
        #expect(try parse(NSNull()).network.name == "proj_front")
        #expect(try parse([String: Any]()).network.name == "proj_front")
        #expect(try parse(["name": "custom"]).network.name == "custom")
    }

    /// An external network exists independently of the project, so it is looked up by its plain key
    /// (or `name:`), never as `<project>_<key>`. Prefixing it pointed `up` at a network that is not there.
    @Test func anExternalNetworkIsNeverProjectPrefixed() throws {
        #expect(try parse(["external": true], key: "shared").network.name == "shared")
        #expect(try parse(["external": true, "name": "corp-net"], key: "shared").network.name == "corp-net")
        #expect(try parse(["external": ["name": "legacy"]], key: "shared").network.name == "legacy")
        #expect(try parse(["external": true], key: "shared").network.external)
        #expect(try parse(["external": false], key: "shared").network.name == "proj_shared")
    }

    @Test func anExternalNetworkIgnoresHowACreatedOneWouldBeConfigured() throws {
        let parsed = try parse(["external": true, "driver": "overlay", "ipam": ["config": [["subnet": "10.0.0.0/8"]]]])
        #expect(parsed.unsupported.isEmpty)
    }

    @Test func internalLabelsAndDriverOptionsAreCaptured() throws {
        let parsed = try parse([
            "internal": true, "labels": ["tier=back", "owner=me"], "driver_opts": ["com.x.mtu": 1400],
        ])
        #expect(parsed.network.isInternal)
        #expect(parsed.network.labels == ["tier": "back", "owner": "me"])
        #expect(parsed.network.driverOpts == ["com.x.mtu": "1400"])
        let mapLabels = try parse(["labels": ["a": "1"]])
        #expect(mapLabels.network.labels == ["a": "1"])
        #expect(throws: (any Error).self) { try parse(["internal": "maybe"]) }
    }

    @Test func ipamSubnetsMapToTheIPv4AndIPv6Flags() throws {
        let parsed = try parse([
            "ipam": ["config": [["subnet": "172.28.0.0/16"], ["subnet": "fd00:1::/64"]]]
        ])
        #expect(parsed.network.subnet == "172.28.0.0/16")
        #expect(parsed.network.subnetV6 == "fd00:1::/64")
        #expect(parsed.unsupported.isEmpty)
    }

    @Test func ipamPartsThatCannotBeHonoredAreRejectedNotDropped() throws {
        let parsed = try parse([
            "ipam": [
                "driver": "weird",
                "config": [["subnet": "172.28.0.0/16", "gateway": "172.28.0.1", "ip_range": "172.28.5.0/24"]],
            ]
        ])
        let keys = Set(parsed.unsupported.map(\.key))
        #expect(keys.contains("networks.front.ipam.gateway"))
        #expect(keys.contains("networks.front.ipam.ip_range"))
        #expect(keys.contains("networks.front.ipam.driver"))
    }

    @Test func aSecondSubnetOfTheSameFamilyIsRejected() throws {
        let parsed = try parse(["ipam": ["config": [["subnet": "10.1.0.0/16"], ["subnet": "10.2.0.0/16"]]]])
        #expect(parsed.network.subnet == "10.1.0.0/16")
        #expect(parsed.unsupported.contains { $0.reason.contains("one IPv4 subnet") })
    }

    @Test(arguments: ["172.28.0.0", "172.28.0/16", "not-a-subnet", "172.28.0.0/"])
    func malformedSubnetsAreErrors(subnet: String) {
        #expect(throws: (any Error).self) { try parse(["ipam": ["config": [["subnet": subnet]]]]) }
    }

    @Test func onlyTheBridgeDriverIsAvailable() throws {
        for driver in ["bridge", "default"] { #expect(try parse(["driver": driver]).unsupported.isEmpty, "\(driver)") }
        for driver in ["overlay", "macvlan", "host"] {
            #expect(try parse(["driver": driver]).unsupported.map(\.key) == ["networks.front.driver"], "\(driver)")
        }
    }

    @Test func unknownNetworkKeysAreRejected() throws {
        #expect(try parse(["whatever": 1]).unsupported.map(\.key) == ["networks.front.whatever"])
        #expect(try parse(["x-note": "hi"]).unsupported.isEmpty)
    }

    @Test func attachableAndIPv6WarnOnlyWhenEnabled() throws {
        #expect(try parse(["attachable": false, "enable_ipv6": false]).warnings.isEmpty)
        #expect(try parse(["attachable": true, "enable_ipv6": true]).warnings.count == 2)
    }

    @Test func createArgsAlwaysCarryTheProjectLabelsAndTheName() throws {
        let plan = try planWith("services:\n  web:\n    image: alpine\n")
        let args = plan.networkCreateArgs(name: "proj_default", key: "default", spec: nil)
        #expect(args == ["network", "create", "--label", "com.docker.compose.project=t", "--label", "com.docker.compose.network=default", "proj_default"])
    }

    @Test func createArgsCarryEveryNetworkSetting() throws {
        var spec = ComposePlanner.ProjectNetwork(name: "t_back", driver: nil, external: false, aliases: [])
        spec.isInternal = true
        spec.subnet = "172.28.0.0/16"
        spec.subnetV6 = "fd00:1::/64"
        spec.labels = ["b": "2", "a": "1"]
        spec.driverOpts = ["k": "v"]
        let plan = try planWith("services:\n  web:\n    image: alpine\n")
        #expect(
            plan.networkCreateArgs(name: "t_back", key: "back", spec: spec) == [
                "network", "create", "--label", "com.docker.compose.project=t", "--label",
                "com.docker.compose.network=back", "--label", "a=1", "--label", "b=2", "--internal", "--subnet",
                "172.28.0.0/16", "--subnet-v6", "fd00:1::/64", "--option", "k=v", "t_back",
            ])
    }

    @Test func downOnlyRemovesNetworksCarryingThisProjectsLabel() throws {
        let json = """
            [
              {"id": "t_default", "configuration": {"name": "t_default", "labels": {"com.docker.compose.project": "t"}}},
              {"id": "t_back", "configuration": {"name": "t_back", "labels": {"com.docker.compose.project": "t"}}},
              {"id": "other_default", "configuration": {"name": "other_default", "labels": {"com.docker.compose.project": "other"}}},
              {"id": "t_legacy", "configuration": {"name": "t_legacy", "labels": {}}},
              {"id": "default", "configuration": {"name": "default", "labels": {}}}
            ]
            """
        #expect(try ComposeScope.ownedNetworkNames(listJSON: json, project: "t") == ["t_default", "t_back"])
        #expect(throws: (any Error).self) { try ComposeScope.ownedNetworkNames(listJSON: "nope", project: "t") }
    }

    @Test func networksFlowThroughThePlanWithExternalNamesIntact() throws {
        let plan = try planWith(
            """
            services:
              web:
                image: alpine
                networks: [front, shared]
            networks:
              front: {internal: true, ipam: {config: [{subnet: 172.28.0.0/16}]}}
              shared: {external: true}
            """)
        #expect(plan.unsupported.isEmpty)
        #expect(plan.networks["front"]?.isInternal == true)
        #expect(plan.networks["shared"]?.name == "shared")
        let svc = try #require(plan.services.first)
        let args = try plan.runArgs(for: svc, detach: true, commandOverride: nil, oneOff: false)
        let nets = args.indices.filter { args[$0] == "--network" }.map { args[$0 + 1] }
        #expect(nets == ["t_front", "shared"], "the external network must be attached by its plain name")
    }

    @Test func anExternalVolumeIsLookedUpByItsPlainKey() throws {
        let plan = try planWith(
            """
            services:
              web:
                image: alpine
                volumes: ["shared:/data", "own:/own"]
            volumes:
              shared: {external: true}
              own: {}
            """)
        #expect(plan.volumes["shared"]?.name == "shared")
        #expect(plan.volumes["shared"]?.external == true)
        #expect(plan.volumes["own"]?.name == "t_own")
        let svc = try #require(plan.services.first)
        let args = try plan.runArgs(for: svc, detach: true, commandOverride: nil, oneOff: false)
        let vols = args.indices.filter { args[$0] == "-v" }.map { args[$0 + 1] }
        #expect(vols.contains("shared:/data"), "got \(vols)")
        #expect(vols.contains("t_own:/own"), "got \(vols)")
    }

    private func planWith(_ yaml: String) throws -> ComposePlanner.Plan {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("compose-net-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("compose.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)
        return try ComposePlanner.plan(fileURL: file, project: "t", profiles: [])
    }
}
