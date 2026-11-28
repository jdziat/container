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

# Behavioral CLI-surface check: walk every subcommand of the built `container` and
# `container-compose` binaries via --help and fail on any ArgumentParser definition error
# (duplicate short flags, uninitialized wrappers). Needs NO running system, so it is safe
# for CI. This is the net for two bugs a compile and the unit tests could not see:
#   - `container compose logs`  (duplicate `-f` short flag; the whole subcommand was unparseable)
#   - `container info`          (uninitialized @Option; covered at run level by a unit test)
#
# Also asserts the Docker-shaped flags that scripts rely on are present, so removing one
# fails here instead of in a user's CI.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN_DIR="${BIN_DIR:-${ROOT}/.build/arm64-apple-macosx/debug}"
CONTAINER="${CONTAINER_BIN:-${BIN_DIR}/container}"
COMPOSE="${COMPOSE_BIN:-${BIN_DIR}/container-compose}"

fail_count=0
checked=0
fail() { printf 'FAIL: %s\n' "$*" >&2; fail_count=$((fail_count + 1)); }
pass() { printf 'PASS: %s\n' "$*"; }

[[ -x "${CONTAINER}" ]] || { echo "missing ${CONTAINER} (swift build first)" >&2; exit 2; }
[[ -x "${COMPOSE}" ]] || { echo "missing ${COMPOSE} (swift build first)" >&2; exit 2; }

# Print the immediate subcommand names from a --help block.
subcommands_of() {
    awk '
        /^[A-Z ]+:$/ { in_sub = ($0 ~ /SUBCOMMANDS|COMMANDS/) ; next }
        in_sub && /^  [a-z]/ { print $1 }
    ' | sed 's/,$//'
}

# Recursively validate `<bin> <path...> --help`.
walk() {
    local bin="$1"; shift
    local out
    out="$("${bin}" "$@" --help 2>&1)" || true
    checked=$((checked + 1))
    if grep -qE "Validation failed|Can't read a value|Multiple \([0-9]+\)" <<<"${out}"; then
        fail "$(basename "${bin}") $* --help"
        grep -E "Validation failed|Can't read a value|Multiple \([0-9]+\)" <<<"${out}" | head -2 >&2
        return
    fi
    local child
    while read -r child; do
        [[ -z "${child}" || "${child}" == "help" ]] && continue
        walk "${bin}" "$@" "${child}"
    done < <(subcommands_of <<<"${out}")
}

walk "${CONTAINER}"
container_walked=${checked}
walk "${COMPOSE}"
compose_walked=$((checked - container_walked))
# `container --help` lists plugin subcommands only while a system is running, so the combined count
# varies with system state. Floors are therefore per binary and must hold either way.
((container_walked >= 80)) || fail "walked only ${container_walked} 'container' commands (expected >= 80)"
((compose_walked >= 20)) || fail "walked only ${compose_walked} 'container-compose' commands (expected >= 20)"

if ((checked < 60)); then
    fail "only walked ${checked} commands; the command tree looks truncated (expected >= 60)"
elif ((fail_count == 0)); then
    pass "walked ${checked} commands; no argument-definition errors"
else
    printf 'walked %d commands; %d argument-definition error(s) above\n' "${checked}" "${fail_count}" >&2
fi

# --- Docker-shaped flags that must exist (name the flag; fail if --help no longer lists it) ---
need() {
    local bin="$1" flag="$2"; shift 2
    if "${bin}" "$@" --help 2>&1 | grep -qE -- "(^|[ ,])${flag}([ ,=<]|$)"; then
        :
    else
        fail "$(basename "${bin}") $* lacks ${flag}"
    fi
}

need "${CONTAINER}" --tail logs
need "${CONTAINER}" --filter list
need "${CONTAINER}" --format list
need "${CONTAINER}" --format inspect
need "${CONTAINER}" --format images
need "${CONTAINER}" --add-host run
need "${CONTAINER}" --sysctl run
need "${CONTAINER}" --stop-signal run
need "${CONTAINER}" --privileged run
need "${CONTAINER}" --security-opt run
need "${CONTAINER}" --pids-limit run
need "${CONTAINER}" --gpus run

need "${COMPOSE}" --follow logs
need "${COMPOSE}" --tail logs
need "${COMPOSE}" --volumes down
need "${COMPOSE}" --timeout down
need "${COMPOSE}" --build up
need "${COMPOSE}" --wait up
need "${COMPOSE}" --force-recreate up
need "${COMPOSE}" --no-deps up
need "${COMPOSE}" --remove-orphans up
need "${COMPOSE}" --quiet ps
need "${COMPOSE}" --no-cache build
need "${COMPOSE}" --rm run
need "${COMPOSE}" --ignore-pull-failures pull

# Compose lifecycle verbs must exist.
for verb in stop start restart rm kill pause unpause top port create up down ps logs exec run build pull images config doctor; do
    "${COMPOSE}" "${verb}" --help >/dev/null 2>&1 || fail "container-compose has no '${verb}' subcommand"
done

if ((fail_count > 0)); then
    printf '\ncli-surface: %d failure(s)\n' "${fail_count}" >&2
    exit 1
fi
pass "CLI_SURFACE_OK (${checked} commands)"
