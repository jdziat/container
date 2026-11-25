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
[[ "$(cc -f "${LF}/c.yml" -p "${PROJ}" ps -q | grep -c .)" == "1" ]] && pass "compose ps -q lists the project's container" || fail "compose ps -q"
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
[[ "$(cc -f "${LF}/c.yml" -f "${LF}/c.yml" up 2>&1)" == *"multiple -f"* ]] && pass "repeating -f is rejected, not silently ignored" || fail "repeated -f accepted"
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

# --- verbs with no equivalent must fail loudly with exit 2, naming an alternative ---------------
for verb in "search x" "import -" "context ls" "buildx ls" "swarm init" "stack ls"; do
    # shellcheck disable=SC2086
    out="$(CONTAINER_BIN="${CONTAINER_BIN}" "${DOCKER_BIN}" ${verb} 2>&1)"; rc=$?
    if [[ ${rc} -eq 2 && "${out}" == docker\ * ]]; then pass "docker ${verb}: unsupported with a clear message"; else fail "docker ${verb}: rc=${rc} out=${out:0:100}"; fi
done

printf '\ndocker corpus: %d passed, %d failed\n' "${passes}" "${failures}"
((failures == 0)) && echo "T2_DOCKER_CORPUS_OK" || exit 1
