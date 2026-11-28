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

/// `compose up web`, `--no-deps`, `--scale` and `--pull`, decided on the plan before anything starts.
struct ComposeSelectionTests {
    // web -> api -> db, plus cache (independent) and tools (profile-gated).
    private let yaml = """
        services:
          db:
            image: postgres
          api:
            image: api
            depends_on: [db]
          web:
            image: web
            depends_on:
              api: {condition: service_started}
              cache: {condition: service_started}
          cache:
            image: redis
          tools:
            image: tools
            profiles: [debug]
        """

    private func plan() throws -> ComposePlanner.Plan {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("compose-sel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("compose.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)
        return try ComposePlanner.plan(fileURL: file, project: "t", profiles: [])
    }
    private func names(_ plan: ComposePlanner.Plan) -> [String] { plan.services.map(\.name) }

    @Test func noNamesLeavesThePlanAlone() throws {
        let p = try plan()
        #expect(Set(names(try p.selecting([], withDependencies: true))) == ["db", "api", "web", "cache"])
    }

    @Test func aNamedServiceBringsItsWholeDependencyChain() throws {
        let selected = try plan().selecting(["web"], withDependencies: true)
        #expect(Set(names(selected)) == ["web", "api", "db", "cache"])
    }

    @Test func aServiceWithNoDependenciesStandsAlone() throws {
        #expect(names(try plan().selecting(["cache"], withDependencies: true)) == ["cache"])
        #expect(names(try plan().selecting(["db"], withDependencies: true)) == ["db"])
    }

    @Test func dependencyOrderIsPreserved() throws {
        let order = names(try plan().selecting(["web"], withDependencies: true))
        func before(_ a: String, _ b: String) -> Bool { order.firstIndex(of: a)! < order.firstIndex(of: b)! }
        #expect(before("db", "api") && before("api", "web") && before("cache", "web"))
    }

    @Test func noDepsStartsOnlyWhatWasNamedAndDropsTheDanglingDependsOn() throws {
        let selected = try plan().selecting(["web"], withDependencies: false)
        #expect(names(selected) == ["web"])
        #expect(
            selected.services.first?.dependsOn.isEmpty == true,
            "a kept service must not still wait on a service that was not started")
    }

    @Test func severalNamesUnionTheirDependencies() throws {
        let selected = try plan().selecting(["api", "cache"], withDependencies: true)
        #expect(Set(names(selected)) == ["api", "db", "cache"])
    }

    @Test func anUnknownServiceIsAnErrorNamingIt() {
        do {
            _ = try plan().selecting(["nope"], withDependencies: true)
            Issue.record("expected an error")
        } catch {
            #expect("\(error)".contains("no such service: nope"))
        }
    }

    @Test func aServiceBehindAnInactiveProfileSaysSo() {
        do {
            _ = try plan().selecting(["tools"], withDependencies: true)
            Issue.record("expected an error")
        } catch {
            #expect("\(error)".contains("profile"), "the error should explain why a declared service is not selectable")
        }
    }

    @Test func scaleSetsReplicasAndLeavesOthersAlone() throws {
        let scaled = try plan().scaled(["web=2", "api=3"])
        #expect(scaled.services.first { $0.name == "web" }?.replicas == 2)
        #expect(scaled.services.first { $0.name == "api" }?.replicas == 3)
        #expect(scaled.services.first { $0.name == "db" }?.replicas == 1)
    }

    @Test func scaleAboveTheCapIsCappedWithAWarning() throws {
        let scaled = try plan().scaled(["web=9"])
        #expect(scaled.services.first { $0.name == "web" }?.replicas == ComposePlanner.Plan.maxReplicas)
        #expect(scaled.warnings.contains { $0.contains("capped") })
    }

    @Test(arguments: ["web", "web=", "web=0", "web=-1", "web=two", "=2", "nope=2"])
    func badScaleSpecsAreRejected(spec: String) {
        #expect(throws: (any Error).self) { try plan().scaled([spec]) }
    }

    @Test func pullOverrideReplacesEveryServicesPolicy() throws {
        let p = try plan().overridingPullPolicy("never")
        #expect(p.services.allSatisfy { $0.options.pullPolicy == .never })
        #expect(try plan().overridingPullPolicy("ALWAYS").services.allSatisfy { $0.options.pullPolicy == .always })
        #expect(try plan().overridingPullPolicy("if_not_present").services.allSatisfy { $0.options.pullPolicy == .missing })
        #expect(throws: (any Error).self) { try plan().overridingPullPolicy("sometimes") }
    }

    @Test func selectingDoesNotChangeTheDeclaredServiceSetUsedForOrphans() throws {
        // `up web` must not turn the other services into orphans for --remove-orphans.
        let narrowed = try plan().selecting(["db"], withDependencies: true)
        #expect(narrowed.declaredServices.isSuperset(of: ["db", "api", "web", "cache", "tools"]))
    }
}
