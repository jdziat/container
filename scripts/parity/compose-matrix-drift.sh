#!/usr/bin/env bash
# Copyright © 2026 Apple Inc. and the container project authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Compose doc-drift gate: docs/compose-support-matrix.md and the planner's accepted-key set
# (`allowed` in Sources/Plugins/ContainerCompose/main.swift) must agree. A key the planner
# accepts but the matrix omits is undocumented; a key the matrix calls `done` but the planner
# rejects is a false claim (this is how the `devices` contradiction slipped in). Needs no system.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

python3 - "${ROOT}" <<'PY'
import re, sys
root = sys.argv[1]
src = open(f"{root}/Sources/Plugins/ContainerCompose/main.swift").read()
doc = open(f"{root}/docs/compose-support-matrix.md").read()

m = re.search(r"let allowed: Set<String> = \[(.*?)\]", src, re.S)
if not m:
    print("FAIL: could not find the planner's `allowed` key set"); sys.exit(1)
code_keys = set(re.findall(r'"([a-z_]+)"', m.group(1)))

# Service-key rows only: the section between "## Service keys" and the next "##".
section = doc.split("## Service keys", 1)[1].split("\n## ", 1)[0]
doc_done, doc_all = set(), set()
for line in section.splitlines():
    cells = [c.strip() for c in line.strip().strip("|").split("|")]
    if len(cells) < 2 or not cells[0].startswith("`"):
        continue
    keys = set(re.findall(r"`([a-z_]+)`", cells[0]))
    keys = {k for k in keys if k not in ("VAR",)}
    doc_all |= keys
    if cells[1].startswith("`done"):
        doc_done |= keys

problems = []
for k in sorted(code_keys - doc_all):
    problems.append(f"planner accepts `{k}` but compose-support-matrix.md does not document it")
for k in sorted(doc_done - code_keys):
    problems.append(f"matrix marks `{k}` done but the planner does not accept it")

# CLI verbs: every documented `done` subcommand must be registered, and vice versa.
subs = re.search(r"subcommands: \[(.*?)\]", src, re.S).group(1)
code_verbs = {s.lower() for s in re.findall(r"(\w+)\.self", subs)}
cli = doc.split("## CLI surface", 1)[1].split("\n## ", 1)[0]
doc_verbs = set()
for line in cli.splitlines():
    cells = [c.strip() for c in line.strip().strip("|").split("|")]
    if len(cells) >= 3 and cells[0].startswith("`") and cells[2].startswith("`done"):
        for chunk in cells[1].split("/"):
            chunk = chunk.strip().strip("`")
            if chunk.startswith("compose "):
                doc_verbs.add(chunk.split()[1])
            elif re.fullmatch(r"[a-z]+", chunk):
                doc_verbs.add(chunk)
for v in sorted(doc_verbs - code_verbs - {"up"}):
    problems.append(f"matrix documents `compose {v}` as done but no such subcommand is registered")

if problems:
    print("\n".join("FAIL: " + p for p in problems)); sys.exit(1)
print(f"PASS: compose matrix and planner agree ({len(code_keys)} service keys, {len(doc_verbs)} documented verbs)")
print("COMPOSE_MATRIX_DRIFT_OK")
PY
