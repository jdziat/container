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

# Docker migration corpus: real `docker ...` one-liners that scripts and CI use, run through
# the `bin/docker` shim against a live system. Every case asserts OBSERVABLE behavior (output
# or state), not that a flag merely parses. Replaces source-text greps as the evidence for the
# "drop-in Docker CLI" claim.
#
# Needs: Apple silicon, macOS 26, `container system start`, and network for the first pull.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONTAINER_BIN="${CONTAINER_BIN:-${ROOT}/bin/container}"
DOCKER_BIN="${DOCKER_BIN:-${ROOT}/bin/docker}"
IMAGE="${PARITY_IMAGE:-alpine:3.20}"
SUFFIX="$$"
NAME="corpus-web-${SUFFIX}"
NAME2="corpus-job-${SUFFIX}"
TAG="corpus-tag-${SUFFIX}:v1"

failures=0
passes=0
pass() { printf 'PASS: %s\n' "$*"; passes=$((passes + 1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }

# d <args...>: run docker, capturing stdout+stderr, stripping the debug-build banner.
d() { CONTAINER_BIN="${CONTAINER_BIN}" "${DOCKER_BIN}" "$@" 2>&1 | grep -v '^Warning! Running debug build'; return "${PIPESTATUS[0]}"; }

# expect_out <description> <expected-substring> <docker args...>
expect_out() {
    local desc="$1" want="$2"; shift 2
    local out
    out="$(d "$@")"
    if [[ "${out}" == *"${want}"* ]]; then pass "${desc}"; else fail "${desc}: wanted '${want}', got: ${out:0:200}"; fi
}

# expect_no_unknown <description> <docker args...>: command must not trip a parser error.
expect_no_unknown() {
    local desc="$1"; shift
    local out
    out="$(d "$@")"
    if grep -qE "Unknown option|Unexpected argument|unknown command|Validation failed|Can't read a value" <<<"${out}"; then
        fail "${desc}: $(grep -E 'Unknown option|Unexpected argument|unknown command|Validation failed|Can.t read' <<<"${out}" | head -1)"
    else
        pass "${desc}"
    fi
}

cleanup() {
    d rm -f "${NAME}" "${NAME2}" >/dev/null 2>&1 || true
    "${CONTAINER_BIN}" image delete "${TAG}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

[[ -x "${DOCKER_BIN}" ]] || { echo "missing ${DOCKER_BIN}" >&2; exit 2; }
"${CONTAINER_BIN}" system status >/dev/null 2>&1 || { echo "container system is not running" >&2; exit 2; }

# Isolation guard: verify the RUNNING apiserver's app root, not just an environment variable.
# An exported CONTAINER_APP_ROOT does not make a running system isolated, and these harnesses
# create and remove containers/volumes/networks. (A live test once deleted a developer's volumes.)
# `make parity-behavioral` starts a system on an isolated root; PARITY_ALLOW_REAL_SYSTEM=1 overrides.
if [[ "${PARITY_ALLOW_REAL_SYSTEM:-0}" != "1" ]]; then
    live_root="$("${CONTAINER_BIN}" system status 2>/dev/null | awk '$1=="paths.appRoot"{print $2}')"
    if [[ -z "${CONTAINER_APP_ROOT:-}" || "${live_root%/}" != "${CONTAINER_APP_ROOT%/}" ]]; then
        echo "refusing to run: the running system's app root is '${live_root}', not the isolated '${CONTAINER_APP_ROOT:-<unset>}'." >&2
        echo "Use 'make parity-behavioral', or set PARITY_ALLOW_REAL_SYSTEM=1 if you accept the risk." >&2
        exit 2
    fi
fi

d pull "${IMAGE}" >/dev/null || fail "docker pull ${IMAGE}"

# --- run with the flags real scripts use ------------------------------------------------------
d run -d --name "${NAME}" --add-host db.internal:10.9.8.7 --sysctl net.ipv4.ip_forward=1 \
    --stop-signal SIGINT -e GREETING=hello "${IMAGE}" sh -c 'echo corpus-line-1; echo corpus-line-2; echo corpus-line-3; sleep 300' >/dev/null \
    && pass "docker run -d --add-host --sysctl --stop-signal -e" || fail "docker run with Docker flags"
sleep 3

expect_out "--add-host writes /etc/hosts"      "10.9.8.7"  exec "${NAME}" cat /etc/hosts
expect_out "--add-host resolves via getent"    "db.internal" exec "${NAME}" getent hosts db.internal
out="$(d exec "${NAME}" cat /proc/sys/net/ipv4/ip_forward)"
[[ "${out}" == "1" ]] && pass "--sysctl applied in guest" || fail "--sysctl: got '${out:0:80}'"
expect_out "-e env reaches the process"        "hello"     exec "${NAME}" sh -c 'echo $GREETING'

# Docker flags the per-VM model cannot honor must warn, not fail, and still run the container.
out="$(d run --rm --privileged --security-opt seccomp=unconfined --pids-limit 50 --gpus all "${IMAGE}" echo ok-unsupported-flags)"
if [[ "${out}" == *"ok-unsupported-flags"* && "${out}" == *"warning: --privileged"* ]]; then
    pass "unsupported run flags warn and still run"
else
    fail "unsupported run flags: ${out:0:200}"
fi

# --- ps: filters and format templates ----------------------------------------------------------
expect_out "ps --format '{{.Names}}'"            "${NAME}"    ps --format '{{.Names}}'
expect_out "ps --format with tab + status"       "running"    ps --format '{{.Names}}\t{{.Status}}'
expect_out "ps --filter name="                   "${NAME}"    ps --filter "name=${NAME}" --format '{{.Names}}'
expect_out "ps --filter status=running"          "${NAME}"    ps --filter status=running --format '{{.Names}}'
ids="$(d ps -aq)"
if [[ "${ids}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}- ]]; then pass "ps -aq prints container ids"; else fail "ps -aq did not print ids: ${ids:0:120}"; fi
out="$(d ps --filter status=exited --filter "name=${NAME}" -q)"
[[ -z "${out}" ]] && pass "ps --filter status=exited excludes a running container" || fail "exited filter matched a running container: ${out}"
expect_no_unknown "ps --filter label="           ps --filter label=nothing -q

# --- inspect / logs / images --------------------------------------------------------------------
expect_out "inspect -f '{{.Name}}'"              "${NAME}"    inspect -f '{{.Name}}' "${NAME}"
expect_out "inspect -f '{{.Status}}'"            "running"    inspect -f '{{.Status}}' "${NAME}"
expect_out "inspect -f '{{json .Name}}'"         "\"${NAME}\"" inspect -f '{{json .Name}}' "${NAME}"
out="$(d logs --tail 2 "${NAME}")"
if [[ "${out}" == *"corpus-line-3"* && "${out}" != *"corpus-line-1"* ]]; then
    pass "logs --tail 2 returns only the last lines"
else
    fail "logs --tail 2: ${out:0:200}"
fi
out="$(d stats --no-stream --format '{{.Name}}|{{.PIDs}}|{{.MemUsage}}' "${NAME}")"
if [[ "${out}" == "${NAME}|"[0-9]*"|"*" / "* ]]; then pass "stats --format template prints name, pids and memory"; else fail "stats --format: ${out:0:160}"; fi
out="$(d stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}' "${NAME}")"
[[ "${out}" == NAME$'\t'CPUPERC* ]] && pass "stats --format 'table ...' prints a header row" || fail "stats table header: ${out:0:120}"
expect_out "images --format Repository:Tag"      "alpine:3.20" images --format '{{.Repository}}:{{.Tag}}'
VOLN="corpusvol${SUFFIX}"
"${CONTAINER_BIN}" volume create "${VOLN}" >/dev/null 2>&1
expect_out "volume ls --format lists a created volume" "${VOLN}" volume ls --format '{{.Name}}'
"${CONTAINER_BIN}" volume delete "${VOLN}" >/dev/null 2>&1
expect_no_unknown "network ls"                   network ls

# --- image verbs that live at the top level in Docker -----------------------------------------
d tag "${IMAGE}" "${TAG}" >/dev/null && pass "docker tag" || fail "docker tag"
expect_out "docker history"                      "CMD"        history "${IMAGE}"
expect_out "docker image ls"                     "alpine"     image ls
expect_no_unknown "docker image inspect"         image inspect "${IMAGE}"
SAVEF="/tmp/corpus-save-${SUFFIX}.tar"
d save -o "${SAVEF}" "${IMAGE}" >/dev/null 2>&1
if [[ -s "${SAVEF}" ]] && tar -tf "${SAVEF}" >/dev/null 2>&1; then pass "docker save writes a valid tar archive"; else fail "docker save produced no valid archive"; fi
rm -f "${SAVEF}"

# --- lifecycle ---------------------------------------------------------------------------------
d stop -t 1 "${NAME}" >/dev/null
expect_out "stop moves container to exited filter" "${NAME}" ps -a --filter status=exited --format '{{.Names}}'
d start "${NAME}" >/dev/null; sleep 2
expect_out "start returns it to running"         "running"    inspect -f '{{.Status}}' "${NAME}"
expect_out "docker top"                          "PID"        top "${NAME}"
d run -d --name "${NAME2}" "${IMAGE}" sleep 60 >/dev/null
d rm -f "${NAME}" "${NAME2}" >/dev/null && pass "docker rm -f (two containers)" || fail "docker rm -f"
out="$(d ps -aq --filter "name=corpus-")"
[[ -z "${out}" ]] && pass "no corpus containers remain" || fail "leftover containers: ${out}"

# --- compose lifecycle: real state transitions through Docker-style global options ---------------
LF="$(mktemp -d)"; PROJ="corpuslife${SUFFIX}"
printf 'services:\n  svc:\n    image: %s\n    command: ["sh","-c","echo from-svc; sleep 300"]\n    ports: ["18080:80"]\n' "${IMAGE}" >"${LF}/c.yml"
cc() { "${CONTAINER_BIN}" compose "$@" 2>&1 | grep -v '^Warning! Running debug build'; }
cstate() { "${CONTAINER_BIN}" ps -a --filter "label=com.docker.compose.project=${PROJ}" --format '{{.Status}}' 2>/dev/null | grep -v '^Warning' | head -1; }
cc -f "${LF}/c.yml" -p "${PROJ}" up -d >/dev/null; sleep 3
[[ "$(cstate)" == "running" ]] && pass "compose -f FILE -p NAME up -d (Docker-style global options)" || fail "compose up: state='$(cstate)'"
# Must equal the project's real container (by name or id). Counting lines would pass on an error message.
psq="$(cc -f "${LF}/c.yml" -p "${PROJ}" ps -q)"
real="$("${CONTAINER_BIN}" ps -a --filter "label=com.docker.compose.project=${PROJ}" --format '{{.Names}} {{.ID}}' 2>/dev/null | grep -v '^Warning')"
if [[ -n "${psq}" && -n "${real}" && "${real}" == *"${psq}"* && "${psq}" != *"rror"* ]]; then pass "compose ps -q lists the project's container"; else fail "compose ps -q: got '${psq:0:100}', expected one of '${real:0:100}'"; fi
cc -f "${LF}/c.yml" -p "${PROJ}" stop -t 1 >/dev/null; [[ "$(cstate)" == "stopped" ]] && pass "compose stop" || fail "compose stop: '$(cstate)'"
cc -f "${LF}/c.yml" -p "${PROJ}" start >/dev/null; sleep 2; [[ "$(cstate)" == "running" ]] && pass "compose start" || fail "compose start: '$(cstate)'"
cc -f "${LF}/c.yml" -p "${PROJ}" pause >/dev/null; [[ "$(cstate)" == "paused" ]] && pass "compose pause" || fail "compose pause: '$(cstate)'"
cc -f "${LF}/c.yml" -p "${PROJ}" unpause >/dev/null; [[ "$(cstate)" == "running" ]] && pass "compose unpause" || fail "compose unpause: '$(cstate)'"
[[ "$(cc -f "${LF}/c.yml" -p "${PROJ}" top svc)" == *"PID"* ]] && pass "compose top shows guest processes" || fail "compose top"
# restart must really restart the guest: age it, restart, and require the uptime to drop.
sleep 8
up_before="$("${CONTAINER_BIN}" exec "$("${CONTAINER_BIN}" ps -q --filter "label=com.docker.compose.project=${PROJ}" 2>/dev/null | grep -v '^Warning' | head -1)" cat /proc/uptime 2>/dev/null | awk '{print int($1)}')"
cc -f "${LF}/c.yml" -p "${PROJ}" restart -t 1 >/dev/null; sleep 3
up_after="$("${CONTAINER_BIN}" exec "$("${CONTAINER_BIN}" ps -q --filter "label=com.docker.compose.project=${PROJ}" 2>/dev/null | grep -v '^Warning' | head -1)" cat /proc/uptime 2>/dev/null | awk '{print int($1)}')"
if [[ -n "${up_before}" && -n "${up_after}" && "${up_before}" -ge 8 && "${up_after}" -lt "${up_before}" ]]; then pass "compose restart really restarts the guest (uptime ${up_before}s -> ${up_after}s)"; else fail "compose restart: uptime ${up_before:-?}s -> ${up_after:-?}s"; fi
cc -f "${LF}/c.yml" -p "${PROJ}" kill >/dev/null; sleep 2
[[ "$(cstate)" == "stopped" ]] && pass "compose kill stops the container" || fail "compose kill: state='$(cstate)'"
cc -f "${LF}/c.yml" -p "${PROJ}" start >/dev/null; sleep 2
# The fixture publishes 18080->80, so `compose port` must report that mapping, not merely not error.
out="$(cc -f "${LF}/c.yml" -p "${PROJ}" port svc 2>&1)"
[[ "${out}" == *"18080"* && "${out}" == *"80"* ]] && pass "compose port reports the published mapping" || fail "compose port did not report 18080->80: ${out:0:160}"
[[ "$(cc "-f${LF}/c.yml" -p"${PROJ}" logs svc)" == *"from-svc"* ]] && pass "compose logs works with attached -fFILE/-pNAME forms" || fail "compose logs / attached short options"
# Several -f files merge (Compose Spec rules). `config` prints the merged plan without starting anything.
printf 'services:\n  svc:\n    environment: {FROM_OVERRIDE: present, LEVEL: over}\n' >"${LF}/o.yml"
printf 'services:\n  svc:\n    image: %s\n    environment: {LEVEL: base, KEEP: me}\n' "${IMAGE}" >"${LF}/b.yml"
merged_cfg="$(cc -f "${LF}/b.yml" -f "${LF}/o.yml" -p "${PROJ}m" config)"
if [[ "${merged_cfg}" == *"LEVEL=over"* && "${merged_cfg}" == *"KEEP=me"* && "${merged_cfg}" == *"FROM_OVERRIDE=present"* ]]; then
    pass "several -f files are merged (later wins, earlier keys kept)"
else
    fail "-f base -f override did not merge: ${merged_cfg:0:200}"
fi
cc -f "${LF}/c.yml" -p "${PROJ}" rm -f -s svc >/dev/null; [[ -z "$(cstate)" ]] && pass "compose rm -f -s removes the container" || fail "compose rm: '$(cstate)'"
# Containers are named after the service, so these must run once the first project's `svc` is gone.
CP="${PROJ}c"
cc -f "${LF}/c.yml" -p "${CP}" create >/dev/null
cst="$("${CONTAINER_BIN}" ps -a --filter "label=com.docker.compose.project=${CP}" --format '{{.Status}}' 2>/dev/null | grep -v '^Warning' | head -1)"
[[ -n "${cst}" && "${cst}" != "running" ]] && pass "compose create makes the container without starting it (state=${cst})" || fail "compose create: state='${cst}'"
cc -f "${LF}/c.yml" -p "${CP}" down -t 1 >/dev/null
cc -f "${LF}/c.yml" -p "${CP}" up -d --build --wait >/dev/null; sleep 2
[[ "$("${CONTAINER_BIN}" ps --filter "label=com.docker.compose.project=${CP}" --format '{{.Status}}' 2>/dev/null | grep -v '^Warning' | head -1)" == "running" ]] \
    && pass "compose up -d --build --wait is accepted and starts the project" || fail "compose up --build --wait"
cc -f "${LF}/c.yml" -p "${CP}" down -t 1 >/dev/null
cc -f "${LF}/c.yml" -p "${PROJ}" down -t 1 >/dev/null; rm -rf "${LF}"

# --- compose up: service selection, --no-deps, --scale, --wait, --pull never -----------------------
# Names carry the run's suffix so they cannot collide with anything else on the system.
SELD="$(mktemp -d)"; SELP="corpussel${SUFFIX}"
DB="seldb${SUFFIX}"; API="selapi${SUFFIX}"; WEB="selweb${SUFFIX}"
printf 'services:\n  %s:\n    image: %s\n    command: ["sleep","300"]\n  %s:\n    image: %s\n    command: ["sleep","300"]\n    depends_on: [%s]\n  %s:\n    image: %s\n    command: ["sleep","300"]\n    depends_on: [%s]\n' \
    "${DB}" "${IMAGE}" "${API}" "${IMAGE}" "${DB}" "${WEB}" "${IMAGE}" "${API}" >"${SELD}/c.yml"
running_names() { "${CONTAINER_BIN}" ps --filter "label=com.docker.compose.project=${SELP}" --format '{{.Names}}' 2>/dev/null | grep -v '^Warning' | sort | tr '\n' ' '; }

cc -f "${SELD}/c.yml" -p "${SELP}" up -d "${WEB}" >/dev/null; sleep 3
got="$(running_names)"
[[ "${got}" == *"${DB}"* && "${got}" == *"${API}"* && "${got}" == *"${WEB}"* ]] \
    && pass "compose up SERVICE also starts what it depends on" || fail "up ${WEB}: running = '${got}'"
cc -f "${SELD}/c.yml" -p "${SELP}" down -t 1 >/dev/null

cc -f "${SELD}/c.yml" -p "${SELP}" up -d --no-deps "${WEB}" >/dev/null; sleep 3
got="$(running_names)"
[[ "${got}" == *"${WEB}"* && "${got}" != *"${DB}"* && "${got}" != *"${API}"* ]] \
    && pass "compose up --no-deps starts only the named service" || fail "up --no-deps ${WEB}: running = '${got}'"
cc -f "${SELD}/c.yml" -p "${SELP}" down -t 1 >/dev/null

cc -f "${SELD}/c.yml" -p "${SELP}" up -d --scale "${DB}=2" "${DB}" >/dev/null; sleep 3
count="$("${CONTAINER_BIN}" ps --filter "label=com.docker.compose.service=${DB}" --format '{{.Names}}' 2>/dev/null | grep -vc '^Warning')"
[[ "${count}" == "2" ]] && pass "compose up --scale SERVICE=2 runs two instances" || fail "up --scale ${DB}=2: ${count} instance(s)"
cc -f "${SELD}/c.yml" -p "${SELP}" down -t 1 >/dev/null

# --wait must not return until the service is healthy: assert health IMMEDIATELY after it returns.
HC="selhc${SUFFIX}"
printf 'services:\n  %s:\n    image: %s\n    command: ["sleep","300"]\n    healthcheck:\n      test: ["CMD-SHELL", "true"]\n      interval: 1s\n      retries: 2\n' "${HC}" "${IMAGE}" >"${SELD}/h.yml"
cc -f "${SELD}/h.yml" -p "${SELP}h" up -d --wait --wait-timeout 90 >/dev/null
if "${CONTAINER_BIN}" inspect "${HC}" 2>/dev/null | grep -qE '"healthStatus" *: *"healthy"'; then
    pass "compose up --wait returns only once the service is healthy"
else
    fail "up --wait returned before ${HC} was healthy"
fi
cc -f "${SELD}/h.yml" -p "${SELP}h" down -t 1 >/dev/null

printf 'services:\n  nope:\n    image: localhost/definitely-not-present-%s:1\n    command: ["true"]\n' "${SUFFIX}" >"${SELD}/n.yml"
out="$(cc -f "${SELD}/n.yml" -p "${SELP}n" up -d --pull never 2>&1)"
[[ "${out}" == *"pull_policy is never"* && "${out}" == *"not present locally"* ]] \
    && pass "compose up --pull never fails clearly when the image is absent" || fail "up --pull never: ${out:0:200}"
out="$(cc -f "${SELD}/c.yml" -p "${SELP}" up -d no-such-service 2>&1)"
[[ "${out}" == *"no such service: no-such-service"* ]] \
    && pass "compose up with an unknown service names it" || fail "up unknown service: ${out:0:160}"
rm -rf "${SELD}"

# --- compose networks: labeled create, label-scoped down, external, internal + ipam ----------------
NETD="$(mktemp -d)"; NP="corpusnet${SUFFIX}"; EXT="extnet${SUFFIX}"
SUBNET="10.$((100 + SUFFIX % 100)).$((SUFFIX % 250)).0/24"
net_exists() { "${CONTAINER_BIN}" network list --format json 2>/dev/null | grep -v '^Warning' | grep -q "\"name\" *: *\"$1\""; }
cleanup_nets() { for n in "${NP}_default" "${NP}_back" "${EXT}"; do "${CONTAINER_BIN}" network delete "$n" >/dev/null 2>&1; done; }

# A same-named network that this project did not create (no compose label) must survive `down`.
"${CONTAINER_BIN}" network create "${NP}_default" >/dev/null 2>&1
printf 'services:\n  n1:\n    image: %s\n    command: ["sleep","300"]\n' "${IMAGE}" >"${NETD}/c.yml"
cc -f "${NETD}/c.yml" -p "${NP}" up -d >/dev/null; sleep 2; cc -f "${NETD}/c.yml" -p "${NP}" down -t 1 >/dev/null
net_exists "${NP}_default" && pass "compose down leaves a same-named network it did not create" \
    || fail "compose down deleted an unlabeled network named ${NP}_default"
"${CONTAINER_BIN}" network delete "${NP}_default" >/dev/null 2>&1

# A network the project creates is labeled, and `down` removes it.
cc -f "${NETD}/c.yml" -p "${NP}" up -d >/dev/null; sleep 2
if "${CONTAINER_BIN}" network list --format json 2>/dev/null | grep -v '^Warning' | grep -q "com.docker.compose.project\" *: *\"${NP}\""; then
    pass "compose labels the networks it creates with the project"
else
    fail "the network created by compose up carries no project label"
fi
cc -f "${NETD}/c.yml" -p "${NP}" down -t 1 >/dev/null
net_exists "${NP}_default" && fail "compose down did not remove its own labeled network" || pass "compose down removes the networks it created"

# External network: attached by its plain name, never created or removed by compose.
"${CONTAINER_BIN}" network create "${EXT}" >/dev/null 2>&1
printf 'services:\n  n1:\n    image: %s\n    command: ["sleep","300"]\n    networks: [outside]\nnetworks:\n  outside:\n    external: true\n    name: %s\n' "${IMAGE}" "${EXT}" >"${NETD}/e.yml"
cc -f "${NETD}/e.yml" -p "${NP}e" up -d >/dev/null; sleep 2
if "${CONTAINER_BIN}" inspect n1 2>/dev/null | grep -q "\"network\" *: *\"${EXT}\""; then pass "an external network is attached by its plain name"; else fail "service is not attached to external network ${EXT}"; fi
cc -f "${NETD}/e.yml" -p "${NP}e" down -t 1 >/dev/null
net_exists "${EXT}" && pass "compose down never removes an external network" || fail "compose down deleted external network ${EXT}"
"${CONTAINER_BIN}" network delete "${EXT}" >/dev/null 2>&1
out="$(cc -f "${NETD}/e.yml" -p "${NP}e" up -d 2>&1)"
[[ "${out}" == *"declared as external, but could not be found"* ]] \
    && pass "a missing external network fails with a clear message" || fail "missing external network: ${out:0:160}"

# internal + ipam subnet produce the network that was asked for.
printf 'services:\n  n1:\n    image: %s\n    command: ["sleep","300"]\n    networks: [back]\nnetworks:\n  back:\n    internal: true\n    ipam:\n      config:\n        - subnet: %s\n' "${IMAGE}" "${SUBNET}" >"${NETD}/i.yml"
cc -f "${NETD}/i.yml" -p "${NP}" up -d >/dev/null; sleep 2
if "${CONTAINER_BIN}" network list --format json 2>/dev/null | grep -v '^Warning' | grep -q "\"ipv4Subnet\" *: *\"${SUBNET}\""; then
    pass "ipam subnet is applied to the created network"
else
    fail "no network with subnet ${SUBNET} after up with ipam.config"
fi
cc -f "${NETD}/i.yml" -p "${NP}" down -t 1 >/dev/null
cleanup_nets; rm -rf "${NETD}"

# --- compose verbs must only ever act on THIS project's containers -------------------------------
# `compose rm -f web` once resolved to any container named `web`. A same-named foreign container
# (here, started with plain `run`) must survive every name-addressed verb run against a project
# that never created it.
CF="$(mktemp -d)"; FOREIGN="web"
printf 'name: corpusproj%s\nservices:\n  web:\n    image: %s\n    command: ["sleep","300"]\n' "${SUFFIX}" "${IMAGE}" >"${CF}/c.yml"
if "${CONTAINER_BIN}" ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "${FOREIGN}"; then
    # A skipped safety check must not read as a pass: on an isolated root nothing should be named this.
    fail "compose-scope check could not run: a container named '${FOREIGN}' already exists"
else
    d run -d --name "${FOREIGN}" "${IMAGE}" sleep 300 >/dev/null; sleep 2
    for v in "rm --file=${CF}/c.yml -f web" "kill --file=${CF}/c.yml web" "stop --file=${CF}/c.yml -t 1 web" "pause --file=${CF}/c.yml web" "restart --file=${CF}/c.yml web"; do
        # shellcheck disable=SC2086
        "${CONTAINER_BIN}" compose ${v} >/dev/null 2>&1
    done
    state="$("${CONTAINER_BIN}" ps -a --filter "name=${FOREIGN}" --format '{{.State}}' 2>/dev/null | grep -v '^Warning' | head -1)"
    [[ "${state}" == "running" ]] && pass "compose rm/kill/stop/pause/restart never touch a same-named foreign container" \
        || fail "compose verb acted on a non-project container named '${FOREIGN}' (state='${state}')"
    d rm -f "${FOREIGN}" >/dev/null 2>&1
fi
rm -rf "${CF}"

# --- down / --force-recreate / --remove-orphans / down -v stay inside the project -----------------
# These are the most-used compose verbs and the most destructive. Each must act only on resources
# carrying THIS project's label: a same-named foreign container or volume must survive, a real
# orphan must go, and the project's own planned containers must NOT be treated as orphans.
SF="$(mktemp -d)"; SP="corpusscope${SUFFIX}"; FC="web"; FV="${SP}_data"
printf 'services:\n  web:\n    image: %s\n    command: ["sleep","300"]\n    volumes: ["data:/d"]\n  tools:\n    image: %s\n    profiles: ["debug"]\n    command: ["sleep","300"]\nvolumes:\n  data: {}\n' "${IMAGE}" "${IMAGE}" >"${SF}/c.yml"
if "${CONTAINER_BIN}" ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "${FC}"; then
    fail "compose down/orphan scope checks could not run: a container named '${FC}' already exists"
else
    "${CONTAINER_BIN}" volume create "${FV}" >/dev/null 2>&1                      # foreign: no compose label
    d run -d --name "${FC}" "${IMAGE}" sleep 300 >/dev/null; sleep 2                # foreign container
    sc() { "${CONTAINER_BIN}" compose "$@" >/dev/null 2>&1; }
    sc -f "${SF}/c.yml" -p "${SP}" down -v -t 1
    "${CONTAINER_BIN}" ps -a --format '{{.Names}}={{.State}}' 2>/dev/null | grep -qx "${FC}=running" \
        && pass "compose down leaves a same-named foreign container running" || fail "compose down destroyed a foreign container named '${FC}'"
    "${CONTAINER_BIN}" volume list 2>/dev/null | grep -q "^${FV}[[:space:]]" \
        && pass "compose down -v leaves a same-named foreign volume" || fail "compose down -v deleted a foreign volume '${FV}'"
    sc -f "${SF}/c.yml" -p "${SP}" up --force-recreate -d
    "${CONTAINER_BIN}" ps -a --format '{{.Names}}={{.State}}' 2>/dev/null | grep -qx "${FC}=running" \
        && pass "up --force-recreate does not delete a same-named foreign container" || fail "up --force-recreate hit the foreign container"
    d rm -f "${FC}" >/dev/null 2>&1; "${CONTAINER_BIN}" volume delete "${FV}" >/dev/null 2>&1
    # remove-orphans: the orphan goes; the project's own planned container must stay up.
    sc -f "${SF}/c.yml" -p "${SP}" up -d; sleep 2
    ORPH="orphan${SUFFIX}"; PROF="profsvc${SUFFIX}"
    d run -d --name "${ORPH}" --label "com.docker.compose.project=${SP}" --label "com.docker.compose.service=ghost" "${IMAGE}" sleep 300 >/dev/null
    # A container of a service that IS declared but whose profile is not active is not an orphan.
    d run -d --name "${PROF}" --label "com.docker.compose.project=${SP}" --label "com.docker.compose.service=tools" "${IMAGE}" sleep 300 >/dev/null; sleep 2
    sc -f "${SF}/c.yml" -p "${SP}" up --remove-orphans -d; sleep 2
    names_now="$("${CONTAINER_BIN}" ps --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')"
    [[ "${names_now}" != *"${ORPH}"* ]] && pass "up --remove-orphans removes a labeled orphan" || fail "orphan survived --remove-orphans"
    [[ "${names_now}" == *"${PROF}"* ]] && pass "up --remove-orphans keeps a container of a declared but profile-disabled service" || fail "--remove-orphans deleted a profile-disabled service's container"
    [[ " ${names_now}" == *" web "* ]] && pass "up --remove-orphans keeps the project's own planned container" || fail "--remove-orphans deleted the project's own container (names: ${names_now})"
    sc -f "${SF}/c.yml" -p "${SP}" down -v -t 1
    d rm -f "${ORPH}" "${PROF}" >/dev/null 2>&1
fi
rm -rf "${SF}"

# --- compose Tier C verbs: ls, ps, cp, run, exec, logs, wait, export, config, --dry-run -------------
# Service names carry the run's suffix so containers (named after the service) cannot collide.
VD="$(mktemp -d)"; VP="corpusverbs${SUFFIX}"; VDB="vdb${SUFFIX}"; VAPI="vapi${SUFFIX}"; VWAIT="vwait${SUFFIX}"
printf 'services:\n  %s:\n    image: %s\n    command: ["sleep","300"]\n  %s:\n    image: %s\n    command: ["sh","-c","echo hello-%s; sleep 300"]\n    depends_on: [%s]\n    ports: ["18097:80"]\n    environment:\n      GREETING: hi\n  %s:\n    image: %s\n    command: ["sh","-c","sleep 3"]\n' \
    "${VDB}" "${IMAGE}" "${VAPI}" "${IMAGE}" "${SUFFIX}" "${VDB}" "${VWAIT}" "${IMAGE}" >"${VD}/c.yml"
vc() { cc -f "${VD}/c.yml" -p "${VP}" "$@"; }

# --dry-run changes nothing: snapshot every container/network/volume before and after.
snap() { for k in "ps -a" "network list" "volume list"; do "${CONTAINER_BIN}" ${k} 2>&1 | grep -v '^Warning'; done | cksum; }
before="$(snap)"; dry="$(cc --dry-run -f "${VD}/c.yml" -p "${VP}" up -d "${VAPI}")"; after="$(snap)"
[[ "${before}" == "${after}" && "${dry}" == *"[dry-run]"*"run"* ]] \
    && pass "compose --dry-run prints the commands and changes nothing" || fail "--dry-run: state changed or nothing printed (${dry:0:120})"

vc up -d "${VAPI}" >/dev/null; sleep 3
[[ "$(vc ls | grep -c "^${VP} ")" == "1" && "$(cc ls | grep -c "^${VP} ")" == "1" ]] \
    && pass "compose ls lists the running project (also with global -f/-p)" || fail "compose ls does not show ${VP} exactly once"
out="$(vc ps)"
[[ "${out}" == NAME* && "${out}" == *"${VDB}"* && "${out}" == *"${VAPI}"* ]] \
    && pass "compose ps lists the project's services (dependency included)" || fail "compose ps: ${out:0:200}"
[[ "$(vc ps --services)" == *"${VAPI}"* ]] && pass "compose ps --services" || fail "compose ps --services"
[[ "$(vc ps --format json)" == *"\"Service\":\"${VAPI}\""* ]] && pass "compose ps --format json uses Compose field names" || fail "compose ps --format json"

# cp is a real round trip: write a file in, read it back out, compare.
printf 'roundtrip-%s' "${SUFFIX}" >"${VD}/in.txt"
vc cp "${VD}/in.txt" "${VAPI}:/tmp/in.txt" >/dev/null && vc cp "${VAPI}:/tmp/in.txt" "${VD}/out.txt" >/dev/null
[[ "$(cat "${VD}/out.txt" 2>/dev/null)" == "roundtrip-${SUFFIX}" ]] && pass "compose cp copies a file in and back out intact" || fail "compose cp round trip"

[[ "$(vc exec -e PROBE=from-exec "${VAPI}" sh -c 'echo $PROBE')" == *"from-exec"* ]] \
    && pass "compose exec -e sets the environment" || fail "compose exec -e"
[[ "$(vc exec "${VAPI}" sh -c 'echo $GREETING')" == *"hi"* ]] && pass "compose exec runs in the service container" || fail "compose exec"
logs="$(vc logs)"
[[ "${logs}" == *"${VAPI}"*"|"*"hello-${SUFFIX}"* ]] && pass "compose logs (all services) prefixes lines with the container name" || fail "compose logs prefix: ${logs:0:160}"
[[ "$(vc logs --no-log-prefix "${VAPI}")" == "hello-${SUFFIX}" ]] && pass "compose logs --no-log-prefix prints the bare line" || fail "compose logs --no-log-prefix"

# run: one-off, deps started, ports NOT published, hidden from `ps`, labelled.
vc stop -t 1 >/dev/null
runout="$(vc run -e ONE=off "${VAPI}" sh -c 'echo ran-$ONE')"
[[ "${runout}" == *"ran-off"* ]] && pass "compose run executes a one-off command with -e" || fail "compose run: ${runout:0:600}"
[[ "$(vc ps | grep -c "${VDB}")" -ge 1 ]] && pass "compose run starts the service's dependencies" || fail "compose run did not start ${VDB}"
vc run -d "${VAPI}" sleep 60 >/dev/null; sleep 2
oneoff="$("${CONTAINER_BIN}" ps -a --filter "label=com.docker.compose.oneoff=True" --filter "label=com.docker.compose.project=${VP}" --format '{{.Names}}' 2>/dev/null | grep -v '^Warning' | head -1)"
[[ -n "${oneoff}" ]] && pass "compose run labels the one-off container" || fail "no com.docker.compose.oneoff container"
[[ "$(vc ps | grep -c '_run_')" == "0" && "$(vc ps -a | grep -c '_run_')" -ge 1 ]] \
    && pass "compose ps hides a running one-off unless -a" || fail "compose ps one-off visibility"
# Inspect the one-off itself: a forwarder with nothing behind it would also make a curl fail.
oneoff_cfg="$("${CONTAINER_BIN}" inspect "${oneoff}" 2>/dev/null | grep -v '^Warning')"
if [[ "${oneoff_cfg}" == *"${oneoff}"* && "${oneoff_cfg}" != *"18097"* ]]; then pass "compose run does not publish the service's ports"; else fail "compose run: one-off config mentions 18097 or could not be inspected"; fi
"${CONTAINER_BIN}" delete -f "${oneoff}" >/dev/null 2>&1

# wait + export + config
vc up -d "${VWAIT}" >/dev/null; sleep 1
vc wait "${VWAIT}" >/dev/null && pass "compose wait returns once the container stops" || fail "compose wait"
vc export "${VWAIT}" -o "${VD}/fs.tar" >/dev/null 2>&1
[[ -s "${VD}/fs.tar" ]] && tar -tf "${VD}/fs.tar" >/dev/null 2>&1 && pass "compose export writes a readable tar" || fail "compose export"
[[ "$(vc ps -a --status exited | grep -c "${VWAIT}")" -ge 1 && "$(vc ps | grep -c "${VWAIT}")" == "0" ]] \
    && pass "compose ps --status exited (Docker's word) finds the stopped container; default ps hides it" || fail "compose ps --status exited"
[[ "$(vc config --services | sort | tr '\n' ' ')" == *"${VAPI}"*"${VDB}"* ]] && pass "compose config --services" || fail "compose config --services"
[[ "$(vc config --format json)" == "{"* ]] && pass "compose config --format json is JSON" || fail "compose config --format json"
[[ "$(cc version --short)" =~ [0-9] ]] && pass "compose version prints a version" || fail "compose version"
vc down -t 1 >/dev/null; rm -rf "${VD}"

# --- remaining live checks: down --rmi, config -q/--volumes, exec/run flags, internal networks, push -------
GD="$(mktemp -d)"; GP="corpusgap${SUFFIX}"
gc() { cc -f "${GD}/$1" -p "${2}" "${@:3}"; }

# config -q prints nothing and succeeds; --volumes lists the declared names.
printf 'services:\n  g:\n    image: %s\n    command: ["sleep","300"]\n    volumes: ["gv%s:/d"]\nvolumes:\n  gv%s: {}\n' "${IMAGE}" "${SUFFIX}" "${SUFFIX}" >"${GD}/v.yml"
[[ -z "$(gc v.yml "${GP}" config -q)" ]] && pass "compose config -q prints nothing for a valid file" || fail "compose config -q printed output"
[[ "$(gc v.yml "${GP}" config --volumes)" == "gv${SUFFIX}" ]] && pass "compose config --volumes lists the declared volume" || fail "compose config --volumes: $(gc v.yml "${GP}" config --volumes | head -2)"
printf 'services:\n  g:\n    image: %s\n    bogus_key_xyz: 1\n' "${IMAGE}" >"${GD}/bad.yml"
[[ -n "$(gc bad.yml "${GP}" config -q 2>&1)" ]] && pass "compose config -q still reports an invalid file" || fail "compose config -q was silent about an invalid key"

# internal: true creates a host-only network (not a NAT one).
printf 'services:\n  g:\n    image: %s\n    command: ["sleep","300"]\n    networks: [back]\nnetworks:\n  back:\n    internal: true\n' "${IMAGE}" >"${GD}/i.yml"
gc i.yml "${GP}i" up -d >/dev/null; sleep 2
"${CONTAINER_BIN}" network inspect "${GP}i_back" 2>/dev/null | grep -q hostOnly \
    && pass "internal: true creates a host-only network" || fail "network ${GP}i_back is not host-only"
gc i.yml "${GP}i" down -t 1 >/dev/null

# exec flags: -w, -u, -d, --index (a scaled service has two replicas).
printf 'services:\n  g:\n    image: %s\n    command: ["sleep","300"]\n' "${IMAGE}" >"${GD}/x.yml"
gc x.yml "${GP}x" up -d --scale g=2 >/dev/null; sleep 3
[[ "$(gc x.yml "${GP}x" exec -w /tmp g pwd)" == "/tmp" ]] && pass "compose exec -w sets the working directory" || fail "compose exec -w"
[[ "$(gc x.yml "${GP}x" exec -u 1000 g id -u)" == "1000" ]] && pass "compose exec -u runs as that user" || fail "compose exec -u"
gc x.yml "${GP}x" exec -d g sh -c 'sleep 1; echo detached > /tmp/d.txt' >/dev/null; sleep 4
[[ "$(gc x.yml "${GP}x" exec g cat /tmp/d.txt 2>&1)" == *"detached"* ]] && pass "compose exec -d runs the command in the background" || fail "compose exec -d"
gc x.yml "${GP}x" exec --index 2 g sh -c 'echo two > /tmp/idx' >/dev/null
[[ "$(gc x.yml "${GP}x" exec --index 2 g cat /tmp/idx 2>&1)" == *"two"* && "$(gc x.yml "${GP}x" exec --index 1 g cat /tmp/idx 2>&1)" != *"two"* ]] \
    && pass "compose exec --index selects the replica" || fail "compose exec --index"

# run flags: -u, -w, --entrypoint, and -d/--name/-l/-p on one detached one-off.
[[ "$(gc x.yml "${GP}x" run -u 1000 g id -u)" == *"1000"* ]] && pass "compose run -u runs as that user" || fail "compose run -u"
[[ "$(gc x.yml "${GP}x" run -w /tmp g pwd)" == *"/tmp"* ]] && pass "compose run -w sets the working directory" || fail "compose run -w"
[[ "$(gc x.yml "${GP}x" run --entrypoint /bin/echo g entrypoint-ok)" == *"entrypoint-ok"* ]] && pass "compose run --entrypoint overrides the entrypoint" || fail "compose run --entrypoint"
gc x.yml "${GP}x" run -d --name "oo${SUFFIX}" -l "probe=yes" -p "$((18300 + SUFFIX % 90)):80" g sleep 60 >/dev/null; sleep 2
cfg="$("${CONTAINER_BIN}" inspect "oo${SUFFIX}" 2>/dev/null | grep -v '^Warning')"
if [[ "${cfg}" == *"oo${SUFFIX}"* && "${cfg}" == *"probe"* && "${cfg}" == *"$((18300 + SUFFIX % 90))"* ]]; then
    pass "compose run -d --name -l -p applies the name, label and published port"
else
    fail "compose run -d --name/-l/-p: name/label/port missing from the one-off's config"
fi
"${CONTAINER_BIN}" delete -f "oo${SUFFIX}" >/dev/null 2>&1
gc x.yml "${GP}x" down -t 1 >/dev/null

# down --rmi: a typo is refused before anything is torn down; `local` removes only the image compose built.
mkdir -p "${GD}/b"; printf 'FROM %s\nCMD ["sleep","300"]\n' "${IMAGE}" >"${GD}/b/Dockerfile"
printf 'services:\n  bsvc:\n    build: ./b\n    command: ["sleep","300"]\n  other:\n    image: %s\n    command: ["sleep","300"]\n' "${IMAGE}" >"${GD}/r.yml"
RP="${GP}r"
gc r.yml "${RP}" up -d >/dev/null; sleep 3
out="$(gc r.yml "${RP}" down --rmi bogus 2>&1)"
[[ "${out}" == *"--rmi must be local or all"* && "$("${CONTAINER_BIN}" ps -q --filter "label=com.docker.compose.project=${RP}" 2>/dev/null | grep -vc '^Warning')" -ge 2 ]] \
    && pass "compose down --rmi <typo> fails before stopping anything" || fail "compose down --rmi bogus: ${out:0:160}"
"${CONTAINER_BIN}" image list 2>/dev/null | grep -q "${RP}_bsvc" || fail "the image compose built (${RP}_bsvc) is not present before down --rmi local"
gc r.yml "${RP}" down -t 1 --rmi local >/dev/null
if "${CONTAINER_BIN}" image list 2>/dev/null | grep -q "${RP}_bsvc"; then fail "down --rmi local left the image compose built"; else pass "compose down --rmi local removes the image compose built"; fi
"${CONTAINER_BIN}" image list 2>/dev/null | grep -q "alpine" && pass "compose down --rmi local keeps images compose did not build" || fail "down --rmi local removed a registry image"

# push: to a throwaway plain-HTTP registry in this isolated system, then read the tag back from its API.
REGPORT=$((15000 + SUFFIX % 900)); REGNAME="corpusreg${SUFFIX}"
"${CONTAINER_BIN}" run -d --name "${REGNAME}" -p "${REGPORT}:5000" docker.io/library/registry:2 >/dev/null 2>&1; sleep 4
PIMG="localhost:${REGPORT}/corpus/push${SUFFIX}:1"
"${CONTAINER_BIN}" image tag "${IMAGE}" "${PIMG}" >/dev/null 2>&1
printf 'services:\n  p:\n    image: %s\n    command: ["sleep","300"]\n' "${PIMG}" >"${GD}/p.yml"
if gc p.yml "${GP}p" push --scheme http >/dev/null 2>&1 && [[ "$(curl -s --max-time 10 "http://localhost:${REGPORT}/v2/corpus/push${SUFFIX}/tags/list")" == *'"1"'* ]]; then
    pass "compose push --scheme http pushes the image to a registry"
else
    fail "compose push --scheme http: the registry has no corpus/push${SUFFIX}:1 tag"
fi
printf 'services:\n  p:\n    build: .\n' >"${GD}/q.yml"
out="$(gc q.yml "${GP}q" push 2>&1)"
[[ "${out}" == *"set \`image:\` to a registry name"* ]] && pass "compose push refuses a service that only has the local build tag" || fail "compose push local tag: ${out:0:160}"
"${CONTAINER_BIN}" delete -f "${REGNAME}" >/dev/null 2>&1
"${CONTAINER_BIN}" image delete "${PIMG}" >/dev/null 2>&1
rm -rf "${GD}"

# --- verbs with no equivalent must fail loudly with exit 2, naming an alternative ---------------
for verb in "search x" "import -" "context ls" "buildx ls" "swarm init" "stack ls"; do
    # shellcheck disable=SC2086
    out="$(CONTAINER_BIN="${CONTAINER_BIN}" "${DOCKER_BIN}" ${verb} 2>&1)"; rc=$?
    if [[ ${rc} -eq 2 && "${out}" == docker\ * ]]; then pass "docker ${verb}: unsupported with a clear message"; else fail "docker ${verb}: rc=${rc} out=${out:0:100}"; fi
done

printf '\ndocker corpus: %d passed, %d failed\n' "${passes}" "${failures}"
((failures == 0)) && echo "T2_DOCKER_CORPUS_OK" || exit 1
