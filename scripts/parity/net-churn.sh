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

# Network create/delete churn: does `container network create|delete` ever hang?
#
# The compose gate hit `network create` blocked for 47 minutes, and `network delete` and `create` blocked for
# the full 10-minute limit, on a self-hosted runner, with no error. This isolates that from compose: create and
# delete user networks with nothing else running, one at a time and then several at once (compose `down` deletes
# networks concurrently), time every call, and fail if any call exceeds its limit. It reports the slowest call in
# each phase so a slow-but-finishing system is visible too.
#
# Phases, in this order because the last one can wedge the network service for the rest of the run:
#   1. sequential   create then delete, one network alive at a time
#   2. coexist      create K networks one after another and KEEP them, then delete them. Separates "several
#                   networks at once is a problem" (a host limit) from "concurrent calls are a problem"
#   3. parallel     PAR creates at once, then PAR deletes at once
#
#   NET_CHURN_N       networks per phase (default 12)
#   NET_CHURN_COEXIST networks kept alive together in phase 2 (default 10)
#   NET_CHURN_LIMIT   seconds before a call counts as hung (default 90)
#   NET_CHURN_PAR     concurrency of the parallel phase (default 4)
set -uo pipefail
# Set to 1 right before every deliberate exit. If the script ends any other way (an unbound variable, a shell
# feature this bash lacks), the EXIT trap below fails the run instead of letting it fall through to a pass.
finished=0

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONTAINER_BIN="${CONTAINER_BIN:-${ROOT}/bin/container}"
N="${NET_CHURN_N:-12}"
LIMIT="${NET_CHURN_LIMIT:-90}"
PAR="${NET_CHURN_PAR:-4}"
COEXIST="${NET_CHURN_COEXIST:-10}"
WT="${ROOT}/scripts/parity/with-timeout.sh"
PREFIX="netchurn$$"

log() { printf '[net-churn] %s\n' "$*"; }
fail() { printf '[net-churn] FAIL: %s\n' "$*" >&2; }

[[ -x "${CONTAINER_BIN}" ]] || { fail "missing executable ${CONTAINER_BIN}"; exit 1; }

# Isolation guard, as in the other harnesses: this creates and deletes networks.
if [[ "${PARITY_ALLOW_REAL_SYSTEM:-0}" != "1" ]]; then
  live_root="$("${CONTAINER_BIN}" system status 2>/dev/null | awk '$1=="paths.appRoot"{print $2}')"
  if [[ -z "${CONTAINER_APP_ROOT:-}" || "${live_root%/}" != "${CONTAINER_APP_ROOT%/}" ]]; then
    echo "refusing to run: the running system's app root is '${live_root}', not the isolated '${CONTAINER_APP_ROOT:-<unset>}'." >&2
    finished=1
    exit 2
  fi
fi

created=()
cleanup() {
  local n
  for n in "${created[@]:-}"; do
    [[ -n "${n}" ]] && bash "${WT}" 60 "${CONTAINER_BIN}" network delete "${n}" >/dev/null 2>&1
  done
  return 0
}
on_exit() {
  cleanup
  if [[ "${finished}" != "1" ]]; then
    echo "[net-churn] FAIL: the harness ended without finishing (a shell error above)" >&2
    exit 1
  fi
}
trap on_exit EXIT

# Printed once, at the first hang: what the host and the container system look like right then.
diagnosed=0
diagnose() {
  [[ "${diagnosed}" == "1" ]] && return 0
  diagnosed=1
  log "---- diagnostics at the first hang ----"
  log "host bridge/vmnet interfaces: $(ifconfig -l | tr ' ' '\n' | grep -cE '^(bridge|vmenet|vmnet)')"
  log "vmnet plugin processes per user:"
  ps -eo user,command | grep '[c]ontainer-network-vmnet start' | awk '{print $1}' | sort | uniq -c | sed 's/^/[net-churn]   /'
  log "this system's networks:"
  "${CONTAINER_BIN}" network list 2>&1 | grep -v '^Warning' | sed 's/^/[net-churn]   /'
  log "recent system log (network / vmnet / lock lines):"
  "${CONTAINER_BIN}" system logs --last 3m 2>&1 | grep -iE "network|vmnet|lock|timeout|bootstrap|launchd|xpc" | tail -25 | cut -c1-260 | sed 's/^/[net-churn]   /'
  log "---- end diagnostics ----"
}

# One timed call. Prints "<exit status> <seconds>"; status 124 means it hung.
timed() {
  local t0 rc
  t0="$(date +%s)"
  bash "${WT}" "${LIMIT}" "$@" >/dev/null 2>&1
  rc=$?
  echo "${rc} $(($(date +%s) - t0))"
}

hung=0 errors=0
# macOS ships bash 3.2: no associative arrays. One variable per phase instead.
slow_sc=0 slow_sd=0 slow_cc=0 slow_cd=0 slow_pc=0 slow_pd=0
record() { # phase-key (sc|sd|pc|pd), label, "<rc> <secs>"
  local key="$1" label="$2" rc="${3%% *}" secs="${3##* }"
  case "${key}" in
    sc) ((secs > slow_sc)) && slow_sc="${secs}" ;;
    sd) ((secs > slow_sd)) && slow_sd="${secs}" ;;
    cc) ((secs > slow_cc)) && slow_cc="${secs}" ;;
    cd) ((secs > slow_cd)) && slow_cd="${secs}" ;;
    pc) ((secs > slow_pc)) && slow_pc="${secs}" ;;
    pd) ((secs > slow_pd)) && slow_pd="${secs}" ;;
  esac
  if [[ "${rc}" == "124" ]]; then
    hung=$((hung + 1))
    diagnose
    fail "${label} hung (> ${LIMIT}s)"
  elif [[ "${rc}" != "0" ]]; then
    errors=$((errors + 1))
    fail "${label} exited ${rc} after ${secs}s"
  fi
  return 0
}

log "isolated system, ${N} networks per phase, hang limit ${LIMIT}s, parallel width ${PAR}"

# Phase 1: strictly sequential create then delete.
for ((i = 1; i <= N; i++)); do
  name="${PREFIX}s${i}"
  created+=("${name}")
  record sc "sequential create" "$(timed "${CONTAINER_BIN}" network create --label "com.docker.compose.project=${PREFIX}" "${name}")"
  record sd "sequential delete" "$(timed "${CONTAINER_BIN}" network delete "${name}")"
done
created=()

# Phase 2: K networks alive at the same time, created one after another. No concurrency here, so a hang at the
# k-th network means the system cannot hold that many; no hang means concurrency is what wedges it.
coexist_names=()
for ((i = 1; i <= COEXIST; i++)); do
  name="${PREFIX}c${i}"
  coexist_names+=("${name}")
  created+=("${name}")
  result="$(timed "${CONTAINER_BIN}" network create --label "com.docker.compose.project=${PREFIX}" "${name}")"
  record cc "coexist create #${i} (${i} alive)" "${result}"
  if [[ "${result%% *}" != "0" ]]; then
    log "stopped creating at #${i}: the system held $((i - 1)) networks of its own plus the default"
    break
  fi
done
for name in "${coexist_names[@]}"; do
  record cd "coexist delete" "$(timed "${CONTAINER_BIN}" network delete "${name}")"
done
created=()

# Phase 3: PAR at once, as compose `up` and `down` do. Each background job writes its own result file so
# results are read after `wait` and never interleave.
tmp="$(mktemp -d)"
for ((batch = 0; batch < N / PAR; batch++)); do
  names=()
  for ((k = 1; k <= PAR; k++)); do names+=("${PREFIX}p${batch}x${k}"); done
  created+=("${names[@]}")
  for name in "${names[@]}"; do
    ( timed "${CONTAINER_BIN}" network create --label "com.docker.compose.project=${PREFIX}" "${name}" >"${tmp}/c.${name}" ) &
  done
  wait
  for name in "${names[@]}"; do record pc "parallel create" "$(cat "${tmp}/c.${name}" 2>/dev/null || echo '1 0')"; done
  for name in "${names[@]}"; do
    ( timed "${CONTAINER_BIN}" network delete "${name}" >"${tmp}/d.${name}" ) &
  done
  wait
  for name in "${names[@]}"; do record pd "parallel delete" "$(cat "${tmp}/d.${name}" 2>/dev/null || echo '1 0')"; done
  created=()
done

log "slowest sequential create: ${slow_sc}s"
log "slowest sequential delete: ${slow_sd}s"
log "slowest coexist create: ${slow_cc}s"
log "slowest coexist delete: ${slow_cd}s"
log "slowest parallel create: ${slow_pc}s"
log "slowest parallel delete: ${slow_pd}s"
log "hung=${hung} errors=${errors}"
if ((hung > 0 || errors > 0)); then
  fail "network churn: ${hung} hung call(s), ${errors} failed call(s)"
  finished=1
  exit 1
fi
finished=1
[[ -n "${tmp:-}" && -d "${tmp}" ]] && rm -rf "${tmp}"
echo "NET_CHURN_OK"
