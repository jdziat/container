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
# (`allowed` in Sources/Plugins/ContainerCompose/ContainerCompose.swift) must agree. A key the planner
# accepts but the matrix omits is undocumented; a key the matrix calls `done` but the planner
# rejects is a false claim (this is how the `devices` contradiction slipped in). Needs no system.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

python3 - "${ROOT}" <<'PY'
import re, sys
root = sys.argv[1]
src = open(f"{root}/Sources/Plugins/ContainerCompose/ContainerCompose.swift").read()
doc = open(f"{root}/docs/compose-support-matrix.md").read()

m = re.search(r"let allowed: Set<String> = \[(.*?)\]", src, re.S)
if not m:
    print("FAIL: could not find the planner's `allowed` key set"); sys.exit(1)
code_keys = set(re.findall(r'"([a-z_]+)"', m.group(1)))

# Keys owned by ServiceOptionsParser: the ignored-with-warning table plus the explicit union list.
opts = open(f"{root}/Sources/Plugins/ContainerCompose/ServiceOptions.swift").read()
ign = re.search(r"static let ignoredWithWarning: \[String: String\] = \[(.*?)\n    \]", opts, re.S)
acc = re.search(r"static let acceptedKeys: Set<String> = .*?\.union\(\[(.*?)\]\)", opts, re.S)
if not ign or not acc:
    print("FAIL: could not find ServiceOptionsParser's key tables"); sys.exit(1)
code_keys |= set(re.findall(r'^\s*"([a-z_]+)":', ign.group(1), re.M))
code_keys |= set(re.findall(r'"([a-z_]+)"', acc.group(1)))

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

# Harness lint: `-f FILE` is a GLOBAL option and must come before the subcommand
# (`compose -f x.yml up`). `compose up -f x.yml` is rejected, and once silently broke the T3 corpus.
# `-p` is the project only before the subcommand; after `run` it means --publish.
import glob
verbs = "config|up|ps|down|logs|exec|run|build|pull|stop|start|restart|rm|kill|pause|unpause|top|port|create|doctor|ls|cp|wait|push|export"
after_f = re.compile(r"compose (?:%s) [^|;&#]*?(?<![\w-])-f[ =]" % verbs)
after_p = re.compile(r"compose (?:%s) [^|;&#]*?(?<![\w-])-p[ =]" % [v for v in [verbs.replace("|run", "")]][0])
for script in sorted(glob.glob(f"{root}/scripts/parity/*.sh")):
    if script.endswith("compose-matrix-drift.sh"):
        continue
    for number, line in enumerate(open(script).read().splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        # `logs -f` (follow) and `rm -f` (force) are legitimate; only a compose FILE argument is wrong.
        if after_f.search(line) and not re.search(r"compose (?:logs|rm) ", line):
            problems.append(f"{script.replace(root + '/', '')}:{number} passes -f after the subcommand; use `compose -f FILE -p NAME <subcommand>`")
        if after_p.search(line):
            problems.append(f"{script.replace(root + '/', '')}:{number} passes -p after the subcommand; use `compose -f FILE -p NAME <subcommand>`")

if problems:
    print("\n".join("FAIL: " + p for p in problems)); sys.exit(1)
print(f"PASS: compose matrix and planner agree ({len(code_keys)} service keys, {len(doc_verbs)} documented verbs)")
print("COMPOSE_MATRIX_DRIFT_OK")
PY
