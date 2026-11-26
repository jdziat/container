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

# Compose corpus harness — Phase 0+/4 gate for Docker-matched compose (+ optional NFS).
# Fixtures 08–10 are production-shaped (WordPress / Nextcloud / Immich) and need a
# longer wall clock for first-time image pulls.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CORPUS="${ROOT}/scripts/parity/compose-corpus"
CONTAINER_BIN="${CONTAINER_BIN:-${ROOT}/bin/container}"
TIMEOUT_S="${COMPOSE_CORPUS_TIMEOUT:-1200}"
SKIP_NFS="${COMPOSE_SKIP_NFS:-0}"
SKIP_PRODUCTION="${COMPOSE_SKIP_PRODUCTION:-0}"

log() { printf '[t3-compose] %s\n' "$*"; }
fail() { printf '[t3-compose] FAIL: %s\n' "$*" >&2; exit 1; }

[[ -x "${CONTAINER_BIN}" ]] || fail "missing executable ${CONTAINER_BIN}"
# Compose plugin shells out via CONTAINER_CLI (default: `container` on PATH).
# Keep it pinned to the same binary the harness invoked.
export CONTAINER_CLI="${CONTAINER_CLI:-${CONTAINER_BIN}}"

# Isolation guard: this harness starts and removes containers, networks and volumes. Verify the RUNNING
# apiserver's app root, not just an environment variable (an exported CONTAINER_APP_ROOT does not make a
# running system isolated). `make parity-behavioral` starts an isolated system; set
# PARITY_ALLOW_REAL_SYSTEM=1 only if you accept the risk.
if [[ "${PARITY_ALLOW_REAL_SYSTEM:-0}" != "1" ]]; then
  live_root="$("${CONTAINER_BIN}" system status 2>/dev/null | awk '$1=="paths.appRoot"{print $2}')"
  if [[ -z "${CONTAINER_APP_ROOT:-}" || "${live_root%/}" != "${CONTAINER_APP_ROOT%/}" ]]; then
    echo "refusing to run: the running system's app root is '${live_root}', not the isolated '${CONTAINER_APP_ROOT:-<unset>}'." >&2
    echo "Use 'make parity-behavioral', or set PARITY_ALLOW_REAL_SYSTEM=1 if you accept the risk." >&2
    exit 2
  fi
fi

compose() {
  "${CONTAINER_BIN}" compose "$@"
}

project_for() {
  printf 'parity-%s' "$1"
}

is_production_fixture() {
  case "$1" in
    08-wordpress|09-nextcloud|10-immich) return 0 ;;
    *) return 1 ;;
  esac
}

http_probe() {
  local url="$1"
  local expect="${2:-}"
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 15 "${url}" || true)"
  if [[ -z "${expect}" ]]; then
    [[ "${code}" =~ ^[123][0-9][0-9]$ ]] || return 1
    return 0
  fi
  [[ "${code}" == "${expect}" ]]
}

wait_http() {
  local url="$1"
  local expect="${2:-}"
  local seconds="${3:-120}"
  local i
  for ((i = 0; i < seconds; i += 5)); do
    if http_probe "${url}" "${expect}"; then
      log "HTTP ${url} ok (${expect:-2xx/3xx})"
      return 0
    fi
    sleep 5
  done
  return 1
}

run_fixture() {
  local dir="$1"
  local name project
  name="$(basename "${dir}")"
  project="$(project_for "${name}")"
  log "=== fixture ${name} (project=${project}) ==="
  pushd "${dir}" >/dev/null

  if is_production_fixture "${name}" && [[ "${SKIP_PRODUCTION}" == "1" ]]; then
    log "SKIP ${name} (COMPOSE_SKIP_PRODUCTION=1)"
    popd >/dev/null
    return 0
  fi

  if [[ "${name}" == "06-nfs" ]]; then
    if [[ "${SKIP_NFS}" == "1" ]]; then
      log "SKIP ${name} (COMPOSE_SKIP_NFS=1)"
      popd >/dev/null
      return 0
    fi
    # Always (re)start the in-guest server unless COMPOSE_NFS_KEEP=1 — stale
    # COMPOSE_NFS_SERVER from a prior session points at a dead address (ETIMEDOUT).
    if [[ "${COMPOSE_NFS_KEEP:-0}" != "1" ]] || [[ -z "${COMPOSE_NFS_SERVER:-}" ]] || [[ -z "${COMPOSE_NFS_EXPORT:-}" ]]; then
      if [[ -x "${ROOT}/scripts/parity/nfs-guest-server.sh" ]]; then
        log "starting in-guest NFS server via nfs-guest-server.sh"
        # shellcheck disable=SC1090
        eval "$("${ROOT}/scripts/parity/nfs-guest-server.sh")"
      elif [[ -z "${COMPOSE_NFS_SERVER:-}" ]] || [[ -z "${COMPOSE_NFS_EXPORT:-}" ]]; then
        log "SKIP ${name} (set COMPOSE_NFS_SERVER and COMPOSE_NFS_EXPORT, or provide nfs-guest-server.sh)"
        popd >/dev/null
        return 0
      fi
    fi
    local tmpdir tmp
    tmpdir="$(mktemp -d)"
    tmp="${tmpdir}/compose.yaml"
    # Portable substitution (avoid requiring gettext envsubst).
    sed -e "s|\${COMPOSE_NFS_SERVER}|${COMPOSE_NFS_SERVER}|g" \
        -e "s|\${COMPOSE_NFS_EXPORT}|${COMPOSE_NFS_EXPORT}|g" \
        compose.yaml > "${tmp}"
    compose -f "${tmp}" -p "${project}" config >/dev/null
    compose -f "${tmp}" -p "${project}" up || { compose -f "${tmp}" -p "${project}" down || true; fail "${name} up"; }
    compose -f "${tmp}" -p "${project}" ps >/dev/null || true
    compose -f "${tmp}" -p "${project}" down || fail "${name} down"
    rm -rf "${tmpdir}"
    popd >/dev/null
    log "OK ${name}"
    return 0
  fi

  # Immich: pin fixture .env into this process so ambient IMMICH_VERSION (etc.)
  # cannot flake the gate. Compose still applies process-over-.env precedence.
  if [[ "${name}" == "10-immich" ]]; then
    set -a
    # shellcheck disable=SC1091
    source ./.env
    set +a
    # Immich folder-check markers under UPLOAD_LOCATION (bind may be empty/gitignored).
    local upload_root="${UPLOAD_LOCATION:-./library}"
    mkdir -p "${upload_root}"
    local sub
    for sub in upload thumbs encoded-video library profile backups; do
      mkdir -p "${upload_root}/${sub}"
      : >"${upload_root}/${sub}/.immich"
    done
  fi

  local config_out
  config_out="$(compose -f compose.yaml -p "${project}" config)" || fail "${name} config"

  # Immich proves ${VAR}/.env interpolation (image tag) and profile skip for ML.
  if [[ "${name}" == "10-immich" ]]; then
    printf '%s\n' "${config_out}" | grep -q 'immich-server:v1.128.0' \
      || fail "${name} config missing interpolated IMMICH_VERSION"
    printf '%s\n' "${config_out}" | grep -q 'immich-machine-learning' \
      && fail "${name} config should omit ML service without profile ml"
  fi

  # Production images (esp. ghcr.io Immich) can 429 on first pull — retry a few times.
  local up_ok=0
  local attempt
  for attempt in 1 2 3 4 5; do
    if compose -f compose.yaml -p "${project}" up; then
      up_ok=1
      break
    fi
    log "up attempt ${attempt} failed for ${name}; retrying after backoff"
    compose -f compose.yaml -p "${project}" down || true
    sleep $((attempt * 15))
  done
  if [[ "${up_ok}" -ne 1 ]]; then
    compose -f compose.yaml -p "${project}" down || true
    fail "${name} up"
  fi
  compose -f compose.yaml -p "${project}" ps >/dev/null || true

  if is_production_fixture "${name}"; then
    # Health-gated apps need longer settle than alpine smoke fixtures.
    sleep 5
    case "${name}" in
      08-wordpress)
        wait_http "http://127.0.0.1:18080/" "302" 180 \
          || { compose -f compose.yaml -p "${project}" logs || true; compose -f compose.yaml -p "${project}" down || true; fail "${name} HTTP probe"; }
        ;;
      09-nextcloud)
        wait_http "http://127.0.0.1:18081/" "" 240 \
          || { compose -f compose.yaml -p "${project}" logs || true; compose -f compose.yaml -p "${project}" down || true; fail "${name} HTTP probe"; }
        ;;
      10-immich)
        # Immich Nest bootstrap + geodata import; require a real HTTP 200 (no ps fallback).
        # Fixture sets IMMICH_HOST=0.0.0.0 so the published port is reachable on 127.0.0.1.
        wait_http "http://127.0.0.1:2283/" "200" 360 \
          || { compose -f compose.yaml -p "${project}" logs || true; compose -f compose.yaml -p "${project}" down || true; fail "${name} HTTP probe (want 200)"; }
        ;;
    esac
  else
    sleep 2
  fi

  compose -f compose.yaml -p "${project}" down || fail "${name} down"
  popd >/dev/null
  log "OK ${name}"
}

main() {
  log "container=${CONTAINER_BIN}"
  local failed=0
  local d
  for d in "${CORPUS}"/[0-9]*; do
    [[ -d "${d}" ]] || continue
    [[ -f "${d}/compose.yaml" ]] || continue
    if ! run_fixture "${d}"; then
      failed=1
    fi
  done
  if [[ "${failed}" -ne 0 ]]; then
    fail "one or more fixtures failed"
  fi
  log "all fixtures passed"
}

# Soft timeout wrapper when available
if command -v gtimeout >/dev/null 2>&1; then
  gtimeout "${TIMEOUT_S}" bash -c "$(declare -f log fail compose project_for is_production_fixture http_probe wait_http run_fixture main); export CONTAINER_BIN CONTAINER_CLI CORPUS ROOT SKIP_NFS SKIP_PRODUCTION; main"
elif command -v timeout >/dev/null 2>&1; then
  timeout "${TIMEOUT_S}" bash -c "$(declare -f log fail compose project_for is_production_fixture http_probe wait_http run_fixture main); export CONTAINER_BIN CONTAINER_CLI CORPUS ROOT SKIP_NFS SKIP_PRODUCTION; main"
else
  main
fi
