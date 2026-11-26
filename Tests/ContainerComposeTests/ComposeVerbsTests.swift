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

/// `compose ps`, `ls`, `cp` and `down --rmi`: the decisions, on fixed `container list` JSON and a fixed plan.
struct ComposeVerbsTests {
    private func row(_ id: String, project: String, service: String, state: String, oneOff: Bool = false, extra: [String: String] = [:]) -> String {
        var labels = ["com.docker.compose.project": project, "com.docker.compose.service": service]
        if oneOff { labels["com.docker.compose.oneoff"] = "True" }
        for (k, v) in extra { labels[k] = v }
        let l = labels.map { "\"\($0.key)\":\"\($0.value)\"" }.joined(separator: ",")
        return "{\"status\":\"\(state)\",\"configuration\":{\"id\":\"\(id)\",\"image\":{\"reference\":\"img-\(service)\"},\"labels\":{\(l)}}}"
    }
    private func list(_ rows: String...) -> String { "[" + rows.joined(separator: ",") + "]" }

    // MARK: ps

    @Test func psKeepsOnlyThisProjectAndMapsStoppedToExited() throws {
        let json = list(
            row("a", project: "p", service: "web", state: "running"),
            row("b", project: "p", service: "db", state: "stopped"),
            row("c", project: "other", service: "web", state: "running"))
        let rows = try ComposePS.rows(listJSON: json, project: "p")
        #expect(rows.map(\.id) == ["b", "a"])  // sorted by service: db, web
        #expect(rows.map(\.state) == ["exited", "running"])
        #expect(rows.first?.image == "img-db")
    }

    @Test func psDefaultsToRunningWithoutOneOffs() throws {
        let rows = try ComposePS.rows(
            listJSON: list(
                row("a", project: "p", service: "web", state: "running"),
                row("b", project: "p", service: "db", state: "stopped"),
                row("c", project: "p", service: "web", state: "running", oneOff: true)), project: "p")
        #expect(ComposePS.filter(rows, all: false, statuses: []).map(\.id) == ["a"])
        #expect(Set(ComposePS.filter(rows, all: true, statuses: []).map(\.id)) == ["a", "b", "c"])
    }

    @Test func psStatusFilterAcceptsDockerSpellingAndImpliesAll() throws {
        let rows = try ComposePS.rows(
            listJSON: list(
                row("a", project: "p", service: "web", state: "running"),
                row("b", project: "p", service: "db", state: "stopped")), project: "p")
        #expect(ComposePS.filter(rows, all: false, statuses: ["exited"]).map(\.id) == ["b"])
        #expect(ComposePS.filter(rows, all: false, statuses: ["stopped"]).map(\.id) == ["b"])
        #expect(ComposePS.filter(rows, all: false, statuses: ["running"]).map(\.id) == ["a"])
    }

    @Test func psJSONUsesComposeFieldNames() throws {
        let rows = try ComposePS.rows(listJSON: list(row("a", project: "p", service: "web", state: "running")), project: "p")
        let json = try ComposePS.json(rows)
        #expect(json.contains("\"Service\":\"web\""))
        #expect(json.contains("\"State\":\"running\""))
        #expect(json.contains("\"Name\":\"a\""))
    }

    @Test func psTableAlignsColumns() {
        let text = ComposePS.table([
            ComposePSRow(name: "web", id: "web", service: "web", image: "nginx", state: "running", oneOff: false)
        ])
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("NAME"))
        let imageColumn = lines[0].distance(from: lines[0].startIndex, to: lines[0].range(of: "IMAGE")!.lowerBound)
        let valueColumn = lines[1].distance(from: lines[1].startIndex, to: lines[1].range(of: "nginx")!.lowerBound)
        #expect(imageColumn == valueColumn)
    }

    @Test func psRejectsGarbage() {
        #expect(throws: ComposeError.self) { try ComposePS.rows(listJSON: "nope", project: "p") }
    }

    // MARK: ls

    @Test func lsGroupsByProjectAndHidesStoppedUnlessAll() throws {
        let json = list(
            row("a", project: "one", service: "web", state: "running", extra: ["com.docker.compose.project.config_files": "/x/compose.yaml"]),
            row("b", project: "one", service: "db", state: "stopped"),
            row("c", project: "two", service: "web", state: "stopped"))
        let running = try ComposeProjects.summaries(listJSON: json, all: false)
        #expect(running.map(\.name) == ["one"])
        #expect(running[0].status == "running(1), exited(1)")
        #expect(running[0].configFiles == "/x/compose.yaml")
        let all = try ComposeProjects.summaries(listJSON: json, all: true)
        #expect(all.map(\.name) == ["one", "two"])
        #expect(all[1].status == "exited(1)")
    }

    @Test func lsIgnoresContainersWithoutAProject() throws {
        let json = "[{\"status\":\"running\",\"configuration\":{\"id\":\"x\",\"labels\":{}}}]"
        #expect(try ComposeProjects.summaries(listJSON: json, all: true).isEmpty)
    }

    // MARK: cp / down --rmi

    private func plan(_ yaml: String) throws -> ComposePlanner.Plan {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("compose-verbs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("compose.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)
        return try ComposePlanner.plan(fileURL: file, project: "t", profiles: [])
    }
    private let yaml = """
        services:
          web:
            image: nginx
          app:
            build: .
          worker:
            image: busybox
            deploy:
              replicas: 2
        """

    @Test func serviceReferenceNeedsAKnownServiceBeforeTheColon() throws {
        let p = try plan(yaml)
        #expect(p.serviceReference("web:/etc/hosts")?.path == "/etc/hosts")
        #expect(p.serviceReference("nosuch:/x") == nil)
        #expect(p.serviceReference("./web:/x") == nil)  // a path, not a service
        #expect(p.serviceReference("/tmp/web:x") == nil)
        #expect(p.serviceReference("plain") == nil)
        // A prefix with a slash is a path even if its text matches nothing; and a service-named path is only
        // a service when there is no slash before the colon.
        #expect(p.serviceReference("sub/web:/x") == nil)
        #expect(p.serviceReference("../web:/x") == nil)
    }

    @Test func copyOutAndIn() throws {
        let p = try plan(yaml)
        let out = try p.copyArguments(source: "web:/etc/hosts", destination: "./hosts", index: 1, owned: ["web"])
        #expect(out == ("web:/etc/hosts", "./hosts"))
        let into = try p.copyArguments(source: "./a.txt", destination: "web:/tmp/a.txt", index: 1, owned: ["web"])
        #expect(into == ("./a.txt", "web:/tmp/a.txt"))
    }

    @Test func copyPicksTheReplicaByIndex() throws {
        let p = try plan(yaml)
        let second = try p.copyArguments(source: "worker:/x", destination: "./x", index: 2, owned: ["worker-1", "worker-2"])
        #expect(second.0 == "worker-2:/x")
        #expect(throws: ComposeError.self) { try p.copyArguments(source: "worker:/x", destination: "./x", index: 3, owned: ["worker-1", "worker-2"]) }
        // Out of range even though the (foreign) container of that name exists: range is checked on its own.
        #expect(throws: ComposeError.self) { try p.copyArguments(source: "worker:/x", destination: "./x", index: 3, owned: ["worker-1", "worker-2", "worker-3"]) }
        #expect(throws: ComposeError.self) { try p.copyArguments(source: "worker:/x", destination: "./x", index: 0, owned: ["worker-1", "worker-2"]) }
    }

    @Test func copyRefusesBadShapes() throws {
        let p = try plan(yaml)
        #expect(throws: ComposeError.self) { try p.copyArguments(source: "./a", destination: "./b", index: 1, owned: ["web"]) }
        #expect(throws: ComposeError.self) { try p.copyArguments(source: "web:/a", destination: "app:/b", index: 1, owned: ["web", "app"]) }
        // a service with no container of ours (not up, or someone else's same-named container)
        #expect(throws: ComposeError.self) { try p.copyArguments(source: "web:/a", destination: "./b", index: 1, owned: []) }
    }

    @Test func rmiLocalIsOnlyWhatComposeBuilt() throws {
        let p = try plan(yaml)
        #expect(try p.imagesToRemove(policy: "local") == ["t_app:latest"])
        #expect(try p.imagesToRemove(policy: "all") == ["busybox", "nginx", "t_app:latest"])
        #expect(throws: ComposeError.self) { try p.imagesToRemove(policy: "everything") }
    }

    // MARK: run / exec / logs / config

    private let runYaml = """
        services:
          db:
            image: postgres
          api:
            image: api
            depends_on: [db]
            ports: ["8080:80"]
            environment:
              A: "1"
              KEEP: old
            user: root
            working_dir: /srv
            entrypoint: ["/bin/old"]
            restart: always
            deploy:
              replicas: 2
        """

    @Test func runDoesNotPublishServicePortsUnlessAsked() throws {
        let p = try plan(runYaml)
        let none = try p.oneOffService("api", overrides: RunOverrides(), hostEnvironment: [:])
        #expect(none.ports.isEmpty)
        let kept = try p.oneOffService("api", overrides: RunOverrides(servicePorts: true), hostEnvironment: [:])
        #expect(kept.ports == ["8080:80"])
        let added = try p.oneOffService("api", overrides: RunOverrides(publish: ["9090:90"]), hostEnvironment: [:])
        #expect(added.ports == ["9090:90"])
        let both = try p.oneOffService("api", overrides: RunOverrides(publish: ["9090:90"], servicePorts: true), hostEnvironment: [:])
        #expect(both.ports == ["8080:80", "9090:90"])
    }

    @Test func runOverridesEnvUserWorkdirEntrypointName() throws {
        let p = try plan(runYaml)
        let svc = try p.oneOffService(
            "api",
            overrides: RunOverrides(
                environment: ["KEEP=new", "ADDED=x=y", "FROMHOST"], user: "nobody", workdir: "/tmp", entrypoint: "/bin/new", name: "mine"),
            hostEnvironment: ["FROMHOST": "h"])
        #expect(svc.environment["KEEP"] == "new")
        #expect(svc.environment["A"] == "1")
        #expect(svc.environment["ADDED"] == "x=y")  // only the first '=' splits
        #expect(svc.environment["FROMHOST"] == "h")
        #expect(svc.user == "nobody")
        #expect(svc.workingDir == "/tmp")
        #expect(svc.entrypoint == ["/bin/new"])
        #expect(svc.containerName == "mine")
    }

    @Test func runEmptyEntrypointClearsIt() throws {
        let svc = try plan(runYaml).oneOffService("api", overrides: RunOverrides(entrypoint: ""), hostEnvironment: [:])
        #expect(svc.entrypoint == nil)
    }

    @Test func runUnsetHostVariableIsNotInvented() throws {
        let svc = try plan(runYaml).oneOffService("api", overrides: RunOverrides(environment: ["NOPE"]), hostEnvironment: [:])
        #expect(svc.environment["NOPE"] == nil)
    }

    @Test func runIsASingleInstanceWithoutRestartPolicy() throws {
        let svc = try plan(runYaml).oneOffService("api", overrides: RunOverrides(), hostEnvironment: [:])
        #expect(svc.replicas == 1)
        #expect(svc.restart == nil)
        #expect(throws: ComposeError.self) { try plan(runYaml).oneOffService("nope", overrides: RunOverrides(), hostEnvironment: [:]) }
    }

    @Test func runDependenciesExcludeTheServiceItself() throws {
        let deps = try plan(runYaml).dependencies(of: "api")
        #expect(deps.services.map(\.name) == ["db"])
        #expect(try plan(runYaml).dependencies(of: "db").services.isEmpty)
    }

    @Test func oneOffRunsAreLabelledSoPsCanHideThem() throws {
        let p = try plan(runYaml)
        let svc = try p.oneOffService("api", overrides: RunOverrides(), hostEnvironment: [:])
        let oneOff = try p.runArgs(for: svc, detach: false, commandOverride: nil, oneOff: true)
        #expect(oneOff.contains("com.docker.compose.oneoff=True"))
        let normal = try p.runArgs(for: svc, detach: true, commandOverride: nil, oneOff: false)
        #expect(!normal.contains("com.docker.compose.oneoff=True"))
    }

    @Test func execArguments() {
        let plain = ComposeExec.arguments(container: "c", command: ["ls", "-l"], detach: false, env: [], user: nil, workdir: nil, tty: false)
        #expect(plain == ["exec", "c", "ls", "-l"])
        let full = ComposeExec.arguments(
            container: "c", command: ["sh"], detach: true, env: ["A=1", "B"], user: "u", workdir: "/w", tty: true)
        #expect(full == ["exec", "--detach", "--interactive", "--tty", "--env", "A=1", "--env", "B", "--user", "u", "--workdir", "/w", "c", "sh"])
    }

    @Test func logPrefixPadsToTheWidestName() {
        #expect(ComposeLogs.prefix("hi", name: "db", width: 5, enabled: true) == "db     | hi")
        #expect(ComposeLogs.prefix("hi", name: "db", width: 5, enabled: false) == "hi")
        #expect(ComposeLogs.prefix("x", name: "longname", width: 3, enabled: true) == "longname  | x")
    }

    @Test func logTargetsAreOwnedContainersInServiceOrder() throws {
        let p = try plan(yaml)
        let all = try ComposeLogs.targets(plan: p, services: [], owned: ["web", "worker-1", "worker-2"])
        #expect(Set(all) == ["web", "worker-1", "worker-2"])
        #expect(try ComposeLogs.targets(plan: p, services: ["worker"], owned: ["web", "worker-1", "worker-2"]) == ["worker-1", "worker-2"])
        #expect(try ComposeLogs.targets(plan: p, services: ["web"], owned: []).isEmpty)
        #expect(throws: ComposeError.self) { try ComposeLogs.targets(plan: p, services: ["nope"], owned: []) }
    }

    @Test func configJSONIsParseableAndComplete() throws {
        let text = try plan(runYaml).summaryJSON()
        let object = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(object["name"] as? String == "t")
        let services = try #require(object["services"] as? [[String: Any]])
        #expect(Set(services.compactMap { $0["name"] as? String }) == ["db", "api"])
        let api = try #require(services.first { $0["name"] as? String == "api" })
        #expect(api["depends_on"] as? [String] == ["db"])
        #expect(api["replicas"] as? Int == 2)
    }

    // MARK: --dry-run

    @Test func dryRunClassifiesReadsAndMutations() {
        for read in [["list", "-a"], ["inspect", "x"], ["logs", "x"], ["network", "list"], ["volume", "inspect", "v"], ["image", "ls"], ["system", "status"], ["--version"]] {
            #expect(!ComposeDryRun.isMutating(read), "\(read) should run")
        }
        for write in [
            ["run", "-d", "img"], ["stop", "x"], ["delete", "-f", "x"], ["kill", "x"], ["exec", "x", "ls"], ["copy", "a", "b"],
            ["network", "create", "n"], ["network", "delete", "n"], ["volume", "create", "v"], ["image", "pull", "i"],
            ["image", "delete", "i"], ["image", "push", "i"], ["builder", "start"], ["system", "start"], ["export", "x"],
            ["somethingnew"],
        ] {
            #expect(ComposeDryRun.isMutating(write), "\(write) must not run")
        }
        #expect(!ComposeDryRun.isMutating([]))
    }

    @Test func dryRunDescribesTheCommandAndQuotesSpaces() {
        #expect(ComposeDryRun.describe(["stop", "-t", "1", "a"]) == "[dry-run] container stop -t 1 a")
        #expect(ComposeDryRun.describe(["run", "--label", "a=b c"]) == "[dry-run] container run --label 'a=b c'")
    }

    @Test func dryRunFlagIsGlobalAndConsumed() throws {
        ComposeDryRun.enabled = false
        defer { ComposeDryRun.enabled = false }
        let args = try ContainerCompose.hoistGlobalOptions(["--dry-run", "-f", "x.yml", "up"])
        #expect(ComposeDryRun.enabled)
        #expect(args == ["up", "--file=x.yml"])
    }

    // MARK: command parsing

    /// The guest command after the service keeps its own flags: `compose exec web sh -c 'x'` must not be read
    /// as options of `exec`. This once failed live with "Unknown option '-c'".
    @Test func commandAfterTheServiceKeepsItsOwnFlags() throws {
        let run = try #require(
            try ContainerCompose.parseAsRoot(["run", "-e", "A=1", "web", "sh", "-c", "echo hi"]) as? ContainerCompose.Run)
        #expect(run.service == "web")
        #expect(run.env == ["A=1"])
        #expect(run.command == ["sh", "-c", "echo hi"])

        let exec = try #require(
            try ContainerCompose.parseAsRoot(["exec", "-u", "root", "web", "ls", "-l", "--color=never", "/"]) as? ContainerCompose.Exec)
        #expect(exec.service == "web")
        #expect(exec.user == "root")
        #expect(exec.command == ["ls", "-l", "--color=never", "/"])
    }

    @Test func optionsBeforeTheServiceStillBelongToTheVerb() throws {
        let run = try #require(try ContainerCompose.parseAsRoot(["run", "-d", "--no-deps", "-w", "/srv", "web", "sleep", "9"]) as? ContainerCompose.Run)
        #expect(run.detach && run.noDeps)
        #expect(run.workdir == "/srv")
        #expect(run.command == ["sleep", "9"])
    }
}
