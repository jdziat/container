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

@testable import ContainerResource

struct GoTemplateTests {
    // Shaped like `ManagedContainer`'s JSON: top-level id, nested configuration/status.
    private let container: [String: Any] = [
        "id": "0b1c-uuid",
        "configuration": [
            "name": "web",
            "image": ["reference": "docker.io/library/nginx:1.27"],
            "labels": ["a": "b"],
        ],
        "status": ["state": "running", "networks": []],
    ]

    @Test func namesResolveToHumanNameNotUUID() throws {
        #expect(try GoTemplate.render("{{.Names}}", row: container) == "web")
        #expect(try GoTemplate.render("{{.ID}}", row: container) == "0b1c-uuid")
    }

    @Test func statusUnwrapsToState() throws {
        #expect(try GoTemplate.render("{{.Status}}", row: container) == "running")
        #expect(try GoTemplate.render("{{.State}}", row: container) == "running")
        #expect(try GoTemplate.render("{{.Image}}", row: container) == "docker.io/library/nginx:1.27")
    }

    @Test func explicitPathsAreNotUnwrappedEarly() throws {
        #expect(try GoTemplate.render("{{.Status.state}}", row: container) == "running")
    }

    @Test func tabsAndNewlineEscapes() throws {
        #expect(try GoTemplate.render("{{.Names}}\\t{{.State}}", row: container) == "web\trunning")
    }

    @Test func functions() throws {
        #expect(try GoTemplate.render("{{upper .State}}", row: container) == "RUNNING")
        #expect(try GoTemplate.render("{{lower .Names}}", row: container) == "web")
        #expect(try GoTemplate.render("{{json .Names}}", row: container) == "\"web\"")
    }

    @Test func missingFieldIsNoValue() throws {
        #expect(try GoTemplate.render("{{.Nope}}", row: container) == "<no value>")
    }

    @Test func imageRepositoryAndTagAreDerived() throws {
        let image: [String: Any] = ["id": "sha256:abc", "configuration": ["name": "docker.io/library/alpine:3.20"]]
        #expect(try GoTemplate.render("{{.Repository}}:{{.Tag}}", row: image) == "docker.io/library/alpine:3.20")
        let noTag: [String: Any] = ["configuration": ["name": "registry:5000/team/app"]]
        #expect(try GoTemplate.render("{{.Repository}}|{{.Tag}}", row: noTag) == "registry:5000/team/app|latest")
        let digest: [String: Any] = ["configuration": ["name": "alpine:3.20@sha256:deadbeef"]]
        #expect(try GoTemplate.render("{{.Tag}}", row: digest) == "3.20")
    }

    @Test func unsupportedActionsFailLoudly() {
        #expect(throws: GoTemplate.Failure.self) { try GoTemplate.render("{{range .}}x{{end}}", row: container) }
        #expect(throws: GoTemplate.Failure.self) { try GoTemplate.render("{{.Names", row: container) }
    }

    @Test func renderedTemplateRunsTheRealEncodeThenRenderPath() throws {
        struct Row: Encodable { let id: String; let configuration: Cfg; struct Cfg: Encodable { let name: String } }
        let payload = [Row(id: "1", configuration: .init(name: "a")), Row(id: "2", configuration: .init(name: "b"))]
        #expect(try Output.renderedTemplate("{{.Names}}", payload: payload) == "a\nb")
    }

    /// A user label called `name` (or `id`, `state`, `reference`) used to replace the WHOLE labels
    /// map with its value, so `{{.Labels}}` printed `WRONG`. Silent wrong data is worse than an error.
    @Test func userControlledMapsAreNeverUnwrapped() throws {
        let row: [String: Any] = [
            "id": "x",
            "configuration": ["name": "web", "labels": ["name": "WRONG", "id": "ALSO-WRONG", "a": "b"]],
            "status": ["state": "running"],
        ]
        let rendered = try GoTemplate.render("{{json .Labels}}", row: row)
        #expect(rendered.contains("\"a\":\"b\""), "labels map must stay a map: \(rendered)")
        #expect(rendered != "\"WRONG\"")
        #expect(try GoTemplate.render("{{.Names}}", row: row) == "web")
    }

    @Test func booleansPrintAsGoDoes() throws {
        let row: [String: Any] = ["configuration": ["name": "x", "readOnly": true, "rosetta": false, "cpus": 4]]
        #expect(try GoTemplate.render("{{.ReadOnly}} {{.Rosetta}} {{.Cpus}}", row: row) == "true false 4")
    }

    @Test func repositoryAndTagBelongToImagesOnly() throws {
        let container: [String: Any] = ["id": "c", "configuration": ["name": "web"], "status": ["state": "running"]]
        #expect(try GoTemplate.render("{{.Repository}}|{{.Tag}}", row: container) == "<no value>|<no value>")
        let digestOnly: [String: Any] = ["configuration": ["name": "alpine@sha256:deadbeef"]]
        #expect(try GoTemplate.render("{{.Repository}}|{{.Tag}}", row: digestOnly) == "alpine|<none>")
    }

    @Test func titleUppercasesWordInitialsAndLeavesTheRest() throws {
        let row: [String: Any] = ["configuration": ["name": "ABC def-ghi"]]
        #expect(try GoTemplate.render("{{title .Names}}", row: row) == "ABC Def-Ghi")
    }

    @Test func tablePrefixPrintsAHeader() throws {
        let rows: [Any] = [
            ["id": "1", "configuration": ["name": "a"], "status": ["state": "running"]],
            ["id": "2", "configuration": ["name": "b"], "status": ["state": "stopped"]],
        ]
        let out = try GoTemplate.render("table {{.Names}}\\t{{.Status}}", rows: rows)
        #expect(out == "NAMES\tSTATUS\na\trunning\nb\tstopped")
    }

    @Test func isTemplateDistinguishesNamedFormats() {
        #expect(GoTemplate.isTemplate("{{.ID}}"))
        #expect(!GoTemplate.isTemplate("json"))
    }
}
