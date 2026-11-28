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

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail() { printf '[r6-gui] FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf '[r6-gui] %s\n' "$*"; }
[[ -f "$ROOT/Sources/ContainerGUI/main.swift" ]] || fail "missing Sources/ContainerGUI/main.swift"
grep -q 'ContainerGUIApp' "$ROOT/Sources/ContainerGUI/main.swift" || fail "missing ContainerGUIApp"
grep -q 'loadLogs' "$ROOT/Sources/ContainerGUI/main.swift" || fail "missing logs pane"
grep -q 'func start' "$ROOT/Sources/ContainerGUI/main.swift" || fail "missing start"
# Honesty guard (parity remediation P4.1): the UI must not claim a framebuffer host unless one
# exists. A real host is an NSViewRepresentable wrapping the VM display; until then the string
# "host active" is a false claim and this check fails the build.
if grep -q 'host active' "$ROOT/Sources/ContainerGUI/main.swift" \
    && ! grep -qE 'NSViewRepresentable|NSViewControllerRepresentable' "$ROOT/Sources/ContainerGUI/main.swift"; then
  fail "GUI claims a framebuffer host but implements none (no NSViewRepresentable)"
fi
grep -q 'container-gui' "$ROOT/Package.swift" || fail "Package.swift missing container-gui target"
# Build + brief launch (open then quit).
cd "$ROOT"
swift build --product container-gui >/tmp/r6-gui-build.log 2>&1 \
  || { tail -40 /tmp/r6-gui-build.log >&2; fail "swift build container-gui"; }
BIN=$(swift build --show-bin-path)/container-gui
[[ -x "$BIN" ]] || fail "missing binary $BIN"
# Headless smoke: binary links and --help/usage isn't required; just that it is Mach-O executable.
file "$BIN" | grep -qi 'Mach-O' || fail "not Mach-O"
ok "R6_CONTAINER_GUI_OK"
