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

/// Compose service keys that map onto `container run` flags. These run without a container system,
/// so the whole mapping is verified in the unit suite.
struct ServiceOptionsTests {
    private func parse(_ body: [String: Any]) throws -> ServiceOptionsParse {
        try ServiceOptionsParser.parse(body: body, service: "web")
    }

    @Test func ulimitsAcceptASingleValueOrSoftAndHard() throws {
        let parsed = try parse(["ulimits": ["nproc": 65535, "nofile": ["soft": 1024, "hard": 2048]]])
        #expect(parsed.options.ulimits == ["nofile=1024:2048", "nproc=65535"])
        #expect(throws: (any Error).self) { try parse(["ulimits": ["nofile": ["soft": 1]]]) }
        #expect(throws: (any Error).self) { try parse(["ulimits": ["a", "b"]]) }
    }

    @Test func sysctlsAcceptAMappingOrAList() throws {
        #expect(try parse(["sysctls": ["net.core.somaxconn": 1024]]).options.sysctls == ["net.core.somaxconn=1024"])
        #expect(try parse(["sysctls": ["net.ipv4.ip_forward=1"]]).options.sysctls == ["net.ipv4.ip_forward=1"])
        #expect(try parse(["sysctls": ["net.ipv4.ip_forward": true]]).options.sysctls == ["net.ipv4.ip_forward=1"])
        #expect(throws: (any Error).self) { try parse(["sysctls": ["no-equals"]]) }
    }

    @Test func extraHostsAcceptMappingAndBothListSeparators() throws {
        #expect(
            try parse(["extra_hosts": ["db": "10.0.0.1", "multi": ["10.0.0.2", "10.0.0.3"]]]).options.extraHosts
                == ["db:10.0.0.1", "multi:10.0.0.2", "multi:10.0.0.3"])
        #expect(
            try parse(["extra_hosts": ["a=10.0.0.1", "b:fd00::5"]]).options.extraHosts == ["a:10.0.0.1", "b:fd00::5"])
        #expect(throws: (any Error).self) { try parse(["extra_hosts": ["nosep"]]) }
    }

    @Test func hostGatewayIsRejectedNotPassedThrough() throws {
        let parsed = try parse(["extra_hosts": ["host.docker.internal:host-gateway"]])
        #expect(parsed.unsupported.map(\.key) == ["extra_hosts"])
        #expect(parsed.options.extraHosts.isEmpty)
    }

    @Test func dnsKeysTakeAScalarOrAList() throws {
        let parsed = try parse(["dns": "1.1.1.1", "dns_search": ["a.test", "b.test"], "dns_opt": ["ndots:2"]])
        #expect(parsed.options.dns == ["1.1.1.1"])
        #expect(parsed.options.dnsSearch == ["a.test", "b.test"])
        #expect(parsed.options.dnsOptions == ["ndots:2"])
    }

    @Test func simpleScalarKeys() throws {
        let parsed = try parse(["stop_signal": "SIGINT", "init": true, "read_only": true, "platform": "linux/amd64"])
        #expect(parsed.options.stopSignal == "SIGINT")
        #expect(parsed.options.useInit && parsed.options.readOnly)
        #expect(parsed.options.platform == "linux/amd64")
        #expect(throws: (any Error).self) { try parse(["init": "maybe"]) }
    }

    @Test(arguments: [
        ("512m", "512M"), ("1g", "1024M"), ("1gb", "1024M"), ("2GiB", "2048M"), ("1.5g", "1536M"),
        ("1073741824", "1024M"), ("64MB", "64M"), ("1k", "1M"),
    ])
    func memorySizesNormalizeToWholeMiB(raw: String, expected: String) throws {
        var warnings: [String] = []
        #expect(try ServiceOptionsParser.normalizeMemory(raw, field: "mem_limit", service: "web", warnings: &warnings) == expected)
    }

    /// Values where rounding up and rounding down disagree. (`1k` alone does not discriminate: a
    /// `max(1, ...)` clamp makes both directions give `1M`.) Under-provisioning memory is the wrong
    /// direction, so these must round UP.
    @Test(arguments: [("1500k", "2M"), ("1.5m", "2M"), ("1025k", "2M"), ("2049k", "3M"), ("100.1m", "101M")])
    func memoryRoundsUpNeverDown(raw: String, expected: String) throws {
        var warnings: [String] = []
        #expect(try ServiceOptionsParser.normalizeMemory(raw, field: "mem_limit", service: "web", warnings: &warnings) == expected)
        #expect(warnings.count == 1, "a rounded value must say so")
    }

    @Test func exactMiBValuesDoNotWarn() throws {
        var warnings: [String] = []
        _ = try ServiceOptionsParser.normalizeMemory("512m", field: "mem_limit", service: "web", warnings: &warnings)
        _ = try ServiceOptionsParser.normalizeMemory("1g", field: "mem_limit", service: "web", warnings: &warnings)
        #expect(warnings.isEmpty)
    }

    @Test func memoryThatIsNotWholeMiBWarnsAndRoundsUp() throws {
        var warnings: [String] = []
        #expect(try ServiceOptionsParser.normalizeMemory("1k", field: "mem_limit", service: "web", warnings: &warnings) == "1M")
        #expect(warnings.count == 1 && warnings[0].contains("rounded up"))
    }

    @Test func badMemorySizesAreRejected() {
        var warnings: [String] = []
        for bad in ["abc", "", "0", "-5m", "12 parsecs", "1.2.3g"] {
            #expect(throws: (any Error).self, "\(bad)") {
                try ServiceOptionsParser.normalizeMemory(bad, field: "mem_limit", service: "web", warnings: &warnings)
            }
        }
    }

    @Test func fractionalCPUsRoundUpWithAWarning() throws {
        let parsed = try parse(["cpus": 0.5])
        #expect(parsed.options.cpus == "1")
        #expect(parsed.warnings.contains { $0.contains("rounded up") })
        #expect(try parse(["cpus": 2]).options.cpus == "2")
        #expect(try parse(["cpus": "3"]).options.cpus == "3")
        #expect(throws: (any Error).self) { try parse(["cpus": 0]) }
        #expect(throws: (any Error).self) { try parse(["cpus": "many"]) }
    }

    @Test func deployResourceLimitsAreReadAndServiceKeysWin() throws {
        let deploy: [String: Any] = ["resources": ["limits": ["cpus": "2", "memory": "256m"]]]
        let fromDeploy = try parse(["deploy": deploy])
        #expect(fromDeploy.options.cpus == "2" && fromDeploy.options.memory == "256M")
        let both = try parse(["deploy": deploy, "cpus": 4, "mem_limit": "1g"])
        #expect(both.options.cpus == "4" && both.options.memory == "1024M")
    }

    @Test func macAddressMustBeWellFormed() throws {
        #expect(try parse(["mac_address": "02:42:ac:11:00:02"]).options.macAddress == "02:42:ac:11:00:02")
        for bad in ["nope", "02:42:ac:11:00", "02-42-ac-11-00-02", "zz:42:ac:11:00:02"] {
            #expect(throws: (any Error).self, "\(bad)") { try parse(["mac_address": bad]) }
        }
    }

    @Test func pullPolicyVariants() throws {
        #expect(try parse(["pull_policy": "always"]).options.pullPolicy == .always)
        #expect(try parse(["pull_policy": "never"]).options.pullPolicy == .never)
        #expect(try parse(["pull_policy": "if_not_present"]).options.pullPolicy == .missing)
        #expect(try parse(["pull_policy": "build"]).options.pullPolicy == .build)
        let daily = try parse(["pull_policy": "daily"])
        #expect(daily.options.pullPolicy == .missing && !daily.warnings.isEmpty)
        #expect(try parse(["pull_policy": "every_12h"]).options.pullPolicy == .missing)
        #expect(throws: (any Error).self) { try parse(["pull_policy": "sometimes"]) }
    }

    @Test func onlyTheDefaultBridgeNetworkModeIsAccepted() throws {
        #expect(try parse(["network_mode": "bridge"]).unsupported.isEmpty)
        #expect(try parse(["network_mode": "default"]).unsupported.isEmpty)
        for mode in ["host", "none", "service:db", "container:abc"] {
            let parsed = try parse(["network_mode": mode])
            #expect(parsed.unsupported.map(\.key) == ["network_mode"], "\(mode)")
        }
    }

    @Test func ignoredKeysWarnOnlyWhenSetToSomethingNonDefault() throws {
        #expect(try parse(["privileged": false, "security_opt": [] as [String], "logging": [String: Any]()]).warnings.isEmpty)
        let warned = try parse(["privileged": true, "logging": ["driver": "syslog"], "cpu_shares": 512])
        #expect(warned.warnings.count == 3)
        #expect(warned.warnings.allSatisfy { $0.contains("accepted but has no effect") })
        #expect(warned.options.runFlags().isEmpty, "ignored keys must not leak into the run flags")
    }

    @Test func ttyAndStdinOpenAreAcceptedWithAnExplanation() throws {
        let parsed = try parse(["tty": true, "stdin_open": true])
        #expect(parsed.warnings.count == 2)
        #expect(parsed.warnings.allSatisfy { $0.contains("detached") })
        #expect(parsed.options.runFlags().isEmpty)
    }

    @Test func runFlagsAreStableAndComplete() {
        var options = ServiceOptions()
        options.ulimits = ["nofile=1:2"]
        options.sysctls = ["a.b=1"]
        options.extraHosts = ["h:10.0.0.1"]
        options.dns = ["1.1.1.1"]
        options.dnsSearch = ["x.test"]
        options.dnsOptions = ["ndots:2"]
        options.stopSignal = "SIGINT"
        options.useInit = true
        options.readOnly = true
        options.platform = "linux/arm64"
        options.cpus = "2"
        options.memory = "512M"
        #expect(
            options.runFlags() == [
                "--ulimit", "nofile=1:2", "--sysctl", "a.b=1", "--add-host", "h:10.0.0.1", "--dns", "1.1.1.1",
                "--dns-search", "x.test", "--dns-option", "ndots:2", "--stop-signal", "SIGINT", "--init",
                "--read-only", "--platform", "linux/arm64", "--cpus", "2", "--memory", "512M",
            ])
        #expect(ServiceOptions().runFlags().isEmpty)
    }

    @Test func rejectedKeysCarryAReasonNotJustNotImplemented() {
        for key in ["links", "external_links", "volumes_from", "group_add", "lifecycle"] {
            #expect(ServiceOptionsParser.rejectedReasons[key]?.isEmpty == false, "\(key)")
            #expect(!ServiceOptionsParser.acceptedKeys.contains(key), "\(key) must stay rejected")
        }
    }
}

/// The same keys, driven end to end through the real planner and `runArgs` (no container system).
struct ComposePlanEndToEndTests {
    private func plan(_ yaml: String) throws -> ComposePlanner.Plan {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("compose-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("compose.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)
        return try ComposePlanner.plan(fileURL: file, project: "t", profiles: [])
    }

    private func args(_ plan: ComposePlanner.Plan, _ service: String = "web", detach: Bool = true) throws -> [String] {
        let svc = try #require(plan.services.first { $0.name == service })
        return try plan.runArgs(for: svc, detach: detach, commandOverride: nil, oneOff: false)
    }

    private func value(after flag: String, in args: [String]) -> [String] {
        args.indices.filter { args[$0] == flag && $0 + 1 < args.count }.map { args[$0 + 1] }
    }

    @Test func newKeysBecomeRunFlags() throws {
        let p = try plan(
            """
            services:
              web:
                image: alpine
                sysctls: {net.core.somaxconn: 1024}
                ulimits: {nofile: {soft: 1024, hard: 2048}}
                extra_hosts: ["db:10.0.0.1"]
                dns: [1.1.1.1]
                stop_signal: SIGINT
                init: true
                read_only: true
                platform: linux/arm64
                mem_limit: 256m
                cpus: 2
            """)
        #expect(p.unsupported.isEmpty)
        let a = try args(p)
        #expect(value(after: "--sysctl", in: a) == ["net.core.somaxconn=1024"])
        #expect(value(after: "--ulimit", in: a) == ["nofile=1024:2048"])
        #expect(value(after: "--add-host", in: a) == ["db:10.0.0.1"])
        #expect(value(after: "--dns", in: a) == ["1.1.1.1"])
        #expect(value(after: "--stop-signal", in: a) == ["SIGINT"])
        #expect(value(after: "--platform", in: a) == ["linux/arm64"])
        #expect(value(after: "--memory", in: a) == ["256M"])
        #expect(value(after: "--cpus", in: a) == ["2"])
        #expect(a.contains("--init") && a.contains("--read-only"))
    }

    @Test func macAddressGoesOnlyOnTheFirstNetwork() throws {
        let p = try plan(
            """
            services:
              web:
                image: alpine
                mac_address: "02:42:ac:11:00:02"
                networks: [front, back]
            networks: {front: {}, back: {}}
            """)
        let nets = value(after: "--network", in: try args(p))
        #expect(nets.count == 2)
        #expect(nets[0].contains("mac=02:42:ac:11:00:02"))
        #expect(!nets[1].contains("mac="))
    }

    @Test func scaleIsTheSameAsReplicas() throws {
        let p = try plan("services:\n  web:\n    image: alpine\n    scale: 2\n")
        #expect(p.services.first?.replicas == 2)
        let both = try plan("services:\n  web:\n    image: alpine\n    scale: 3\n    deploy: {replicas: 2}\n")
        #expect(both.services.first?.replicas == 2, "deploy.replicas wins")
    }

    @Test func rejectedKeysSurfaceTheirReasonThroughThePlan() throws {
        let p = try plan(
            """
            services:
              web:
                image: alpine
                links: [db]
                network_mode: host
                volumes_from: [db]
            """)
        let reasons = Dictionary(uniqueKeysWithValues: p.unsupported.map { ($0.key, $0.reason) })
        #expect(reasons["links"]?.contains("legacy") == true)
        #expect(reasons["network_mode"]?.contains("not supported") == true)
        #expect(reasons["volumes_from"]?.contains("named volume") == true)
        #expect(throws: (any Error).self) { try p.reportUnsupported() }
    }

    @Test func ignoredKeysAreWarnedAboutOnThePlanAndNeverBecomeFlags() throws {
        let p = try plan("services:\n  web:\n    image: alpine\n    privileged: true\n    pid: host\n")
        #expect(p.unsupported.isEmpty)
        #expect(p.warnings.count == 2)
        let a = try args(p)
        #expect(!a.contains("--privileged") && !a.contains("--pid"))
    }
}
