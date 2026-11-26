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

/// Compose Spec merge rules for `-f a.yml -f b.yml`, and the file/argument plumbing around them.
struct ComposeMergeTests {
    private func svc(_ body: [String: Any]) -> [String: Any] { ["services": ["web": body]] }
    private func merged(_ a: [String: Any], _ b: [String: Any]) -> [String: Any] {
        let result = ComposeMerge.merge(svc(a), svc(b))
        return (result["services"] as? [String: Any])?["web"] as? [String: Any] ?? [:]
    }
    private func strings(_ value: Any?) -> [String] { (value as? [Any])?.map { "\($0)" } ?? [] }

    @Test func laterScalarsWinAndEarlierKeysSurvive() {
        let r = merged(["image": "a", "restart": "no"], ["image": "b"])
        #expect(r["image"] as? String == "b")
        #expect(r["restart"] as? String == "no")
    }

    @Test func environmentMergesAcrossListAndMapForms() {
        let r = merged(["environment": ["A=1", "B=1"]], ["environment": ["B": "2", "C": "3"]])
        let env = r["environment"] as? [String: Any]
        #expect(env?["A"] as? String == "1")
        #expect(env?["B"] as? String == "2", "the later file wins")
        #expect(env?["C"] as? String == "3")
    }

    @Test func listFormEnvironmentWithABareNameKeepsAHostPassthrough() {
        let r = merged(["environment": ["FROM_HOST"]], ["environment": ["X=1"]])
        let env = r["environment"] as? [String: Any]
        #expect(env?["FROM_HOST"] is NSNull)
        #expect(env?["X"] as? String == "1")
    }

    @Test func portsAreAppendedWithoutDuplicates() {
        let r = merged(["ports": ["80:80", "443:443"]], ["ports": ["443:443", "8080:8080"]])
        #expect(strings(r["ports"]) == ["80:80", "443:443", "8080:8080"])
    }

    @Test func aVolumeForTheSameTargetReplacesTheEarlierOneInsteadOfDuplicatingIt() {
        // Two mounts at one target would make `container run` fail; the later file must take over.
        let r = merged(
            ["volumes": ["./a:/data", "cache:/cache"]],
            ["volumes": ["./b:/data", "./logs:/logs"]])
        #expect(strings(r["volumes"]) == ["./b:/data", "cache:/cache", "./logs:/logs"])
    }

    @Test func longFormVolumesAreKeyedByTarget() {
        let first: [String: Any] = ["type": "bind", "source": "./a", "target": "/data"]
        let second: [String: Any] = ["type": "bind", "source": "./b", "target": "/data"]
        let r = merged(["volumes": [first]], ["volumes": [second]])
        let list = r["volumes"] as? [[String: Any]]
        #expect(list?.count == 1)
        #expect(list?.first?["source"] as? String == "./b")
    }

    @Test func commandAndEntrypointAreReplacedNeverAppended() {
        let r = merged(
            ["command": ["sh", "-c", "old"], "entrypoint": ["/old"]],
            ["command": ["new"], "entrypoint": ["/new", "x"]])
        #expect(strings(r["command"]) == ["new"])
        #expect(strings(r["entrypoint"]) == ["/new", "x"])
    }

    @Test func dependsOnListMergesWithMapAndKeepsConditions() {
        let r = merged(
            ["depends_on": ["db", "cache"]],
            ["depends_on": ["db": ["condition": "service_healthy"]]])
        let deps = r["depends_on"] as? [String: Any]
        #expect((deps?["db"] as? [String: Any])?["condition"] as? String == "service_healthy")
        #expect((deps?["cache"] as? [String: Any])?["condition"] as? String == "service_started")
    }

    @Test func networksListAndMapMerge() {
        let r = merged(["networks": ["front"]], ["networks": ["back": ["aliases": ["api"]]]])
        let nets = r["networks"] as? [String: Any]
        #expect(Set(nets?.keys ?? [:].keys) == ["front", "back"])
    }

    @Test func aBuildStringIsTheContextAndMergesWithABuildMapping() {
        let r = merged(["build": "./app"], ["build": ["args": ["V": "2"]]])
        let build = r["build"] as? [String: Any]
        #expect(build?["context"] as? String == "./app")
        #expect((build?["args"] as? [String: Any])?["V"] as? String == "2")
    }

    @Test func healthcheckMergesFieldByFieldAndReplacesTheTest() {
        let r = merged(
            ["healthcheck": ["test": ["CMD", "old"], "interval": "5s"]],
            ["healthcheck": ["test": ["CMD", "new"]]])
        let health = r["healthcheck"] as? [String: Any]
        #expect(strings(health?["test"]) == ["CMD", "new"])
        #expect(health?["interval"] as? String == "5s")
    }

    @Test func labelsMergeAcrossListAndMapForms() {
        let r = merged(["labels": ["a=1"]], ["labels": ["b": "2"]])
        let labels = r["labels"] as? [String: Any]
        #expect(labels?["a"] as? String == "1" && labels?["b"] as? String == "2")
    }

    @Test func devicesAreKeyedByTheContainerPath() {
        let r = merged(["devices": ["/dev/a:/dev/x"]], ["devices": ["/dev/b:/dev/x", "/dev/c:/dev/y"]])
        #expect(strings(r["devices"]) == ["/dev/b:/dev/x", "/dev/c:/dev/y"])
    }

    @Test func aServiceOnlyInTheLaterFileIsAdded() {
        let result = ComposeMerge.merge(
            ["services": ["web": ["image": "a"]]], ["services": ["extra": ["image": "b"]]])
        #expect(Set((result["services"] as? [String: Any])?.keys ?? [:].keys) == ["web", "extra"])
    }

    @Test func topLevelVolumesWithAnEmptyLaterEntryKeepTheEarlierDefinition() {
        let result = ComposeMerge.merge(
            ["volumes": ["data": ["driver": "local"]]], ["volumes": ["data": NSNull(), "extra": [String: Any]()]])
        let volumes = result["volumes"] as? [String: Any]
        #expect((volumes?["data"] as? [String: Any])?["driver"] as? String == "local")
        #expect(volumes?["extra"] != nil)
    }

    @Test func projectNameFromALaterFileWins() {
        #expect(ComposeMerge.merge(["name": "a"], ["name": "b"])["name"] as? String == "b")
    }
}

struct ComposeFilesTests {
    private let dir = URL(fileURLWithPath: "/proj")
    private func resolve(
        explicit: [String] = [], env: [String: String] = [:], present: Set<String> = []
    ) throws -> [String] {
        try ComposeFiles.resolve(
            explicit: explicit, environment: env, directory: dir, exists: { present.contains($0.lastPathComponent) }
        ).map(\.path)
    }

    @Test func explicitFilesWinOverTheEnvironmentAndAreNotAugmentedWithAnOverride() throws {
        let files = try resolve(
            explicit: ["a.yml", "b.yml"], env: ["COMPOSE_FILE": "x.yml"], present: ["compose.yaml", "compose.override.yaml"])
        #expect(files == ["/proj/a.yml", "/proj/b.yml"])
    }

    @Test func composeFileUsesTheColonSeparatorByDefaultAndHonorsACustomOne() throws {
        #expect(try resolve(env: ["COMPOSE_FILE": "a.yml:b.yml"]) == ["/proj/a.yml", "/proj/b.yml"])
        #expect(
            try resolve(env: ["COMPOSE_FILE": "a.yml;b.yml", "COMPOSE_PATH_SEPARATOR": ";"]) == ["/proj/a.yml", "/proj/b.yml"])
    }

    @Test func theDefaultFileAndItsOverrideAreLoadedTogether() throws {
        #expect(
            try resolve(present: ["compose.yaml", "compose.override.yaml"]) == ["/proj/compose.yaml", "/proj/compose.override.yaml"]
        )
        #expect(try resolve(present: ["compose.yaml"]) == ["/proj/compose.yaml"])
    }

    @Test func defaultNamesAreTriedInDockersOrder() throws {
        #expect(try resolve(present: ["docker-compose.yml", "compose.yml"]) == ["/proj/compose.yml"])
        #expect(
            try resolve(present: ["docker-compose.yml", "docker-compose.override.yml"])
                == ["/proj/docker-compose.yml", "/proj/docker-compose.override.yml"])
    }

    @Test func anOverrideAloneIsNotAProject() {
        #expect(throws: (any Error).self) { try resolve(present: ["compose.override.yaml"]) }
    }

    @Test func noFileAtAllNamesWhatWasLookedFor() {
        do {
            _ = try resolve()
            Issue.record("expected an error")
        } catch {
            let text = "\(error)"
            #expect(text.contains("compose.yaml") && text.contains("docker-compose.yml"))
        }
    }
}

struct ComposeHoistTests {
    private func hoist(_ args: [String]) throws -> [String] { try ContainerCompose.hoistGlobalOptions(args) }

    @Test func globalOptionsMoveBehindTheSubcommandInOrder() throws {
        #expect(
            try hoist(["-f", "a.yml", "-f", "b.yml", "-p", "x", "up", "-d"])
                == ["up", "--file=a.yml", "--file=b.yml", "--project=x", "-d"])
    }

    @Test func newGlobalOptionsAreHoistedToo() throws {
        #expect(
            try hoist(["--env-file", "e.env", "--project-directory", "/p", "ps"])
                == ["ps", "--env-file=e.env", "--project-directory=/p"])
    }

    @Test func attachedShortAndEqualsForms() throws {
        #expect(try hoist(["-fa.yml", "-pname", "ps"]) == ["ps", "--file=a.yml", "--project=name"])
        #expect(try hoist(["--file=a.yml", "--project-name=n", "ps"]) == ["ps", "--file=a.yml", "--project=n"])
    }

    @Test func optionsAfterTheSubcommandAreLeftAloneSoLogsFollowStaysFollow() throws {
        #expect(try hoist(["logs", "-f", "web"]) == ["logs", "-f", "web"])
        #expect(try hoist(["-f", "a.yml", "rm", "-f", "web"]) == ["rm", "--file=a.yml", "-f", "web"])
    }

    @Test func helpAndUnknownLeadingOptionsPassThroughUntouched() throws {
        #expect(try hoist(["--help"]) == ["--help"])
        #expect(try hoist(["--wat", "up"]) == ["--wat", "up"])
    }

    @Test func aMissingValueIsAnErrorNotASilentDrop() {
        #expect(throws: (any Error).self) { try hoist(["-f"]) }
    }
}

struct ComposeMultiFilePlanTests {
    private func write(_ files: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("compose-multi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, text) in files { try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        return dir
    }
    private func value(after flag: String, in args: [String]) -> [String] {
        args.indices.filter { args[$0] == flag && $0 + 1 < args.count }.map { args[$0 + 1] }
    }

    @Test func twoFilesMergeIntoOnePlan() throws {
        let dir = try write([
            "base.yaml": "services:\n  web:\n    image: alpine\n    environment: [A=1, B=1]\n    ports: ['80:80']\n",
            "over.yaml":
                "services:\n  web:\n    environment: {B: '2'}\n    ports: ['8080:80']\n  extra:\n    image: busybox\n",
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let plan = try ComposePlanner.plan(
            fileURLs: [dir.appendingPathComponent("base.yaml"), dir.appendingPathComponent("over.yaml")],
            project: "t", profiles: [])
        #expect(Set(plan.services.map(\.name)) == ["web", "extra"])
        let web = try #require(plan.services.first { $0.name == "web" })
        let args = try plan.runArgs(for: web, detach: true, commandOverride: nil, oneOff: false)
        #expect(value(after: "-e", in: args).contains("A=1"))
        #expect(value(after: "-e", in: args).contains("B=2"), "the later file's value wins")
        #expect(value(after: "-p", in: args) == ["80:80", "8080:80"])
    }

    @Test func relativePathsResolveAgainstTheFirstFilesDirectory() throws {
        let dir = try write(["a.yaml": "services:\n  web:\n    image: alpine\n    env_file: [common.env]\n", "common.env": "K=V\n"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let plan = try ComposePlanner.plan(fileURLs: [dir.appendingPathComponent("a.yaml")], project: "t", profiles: [])
        let args = try plan.runArgs(
            for: try #require(plan.services.first), detach: true, commandOverride: nil, oneOff: false)
        #expect(value(after: "-e", in: args).contains("K=V"))
    }

    @Test func projectNameComesFromComposeProjectNameInDotEnvBeforeTheFileName() throws {
        let dir = try write([
            "compose.yaml": "name: fromfile\nservices:\n  web:\n    image: alpine\n", ".env": "COMPOSE_PROJECT_NAME=fromdotenv\n",
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("compose.yaml")
        #expect(try ComposePlanner.plan(fileURLs: [url], project: nil, profiles: []).project == "fromdotenv")
        #expect(try ComposePlanner.plan(fileURLs: [url], project: "explicit", profiles: []).project == "explicit")
    }

    @Test func envFileReplacesDotEnvAndLaterFilesWin() throws {
        let dir = try write([
            "compose.yaml": "services:\n  web:\n    image: alpine:${TAG}\n", ".env": "TAG=dotenv\n", "one.env": "TAG=one\n",
            "two.env": "TAG=two\n",
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("compose.yaml")
        func image(_ envFiles: [URL]) throws -> String? {
            try ComposePlanner.plan(fileURLs: [url], project: "t", profiles: [], envFiles: envFiles).services.first?.image
        }
        #expect(try image([]) == "alpine:dotenv")
        #expect(try image([dir.appendingPathComponent("one.env")]) == "alpine:one")
        #expect(try image([dir.appendingPathComponent("one.env"), dir.appendingPathComponent("two.env")]) == "alpine:two")
        #expect(throws: (any Error).self) { try image([dir.appendingPathComponent("missing.env")]) }
    }
}
