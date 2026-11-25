#!/usr/bin/env bash
# Bring up an in-guest NFS server for local NFS e2e (no host nfsd/sudo required).
# Requires a guest kernel with NFS client+server (CONFIG_NFS_FS / CONFIG_NFSD).
set -euo pipefail

CONTAINER_BIN="${CONTAINER_BIN:-container}"
NETWORK="${NFS_TEST_NETWORK:-nfsnet}"
NAME="${NFS_TEST_SERVER_NAME:-nfsserver}"
EXPORT_PATH="${NFS_TEST_EXPORT_PATH:-/export}"

# Logs go to stderr so `eval "$(…)"` only sees export lines on stdout.
log() { printf '[nfs-guest-server] %s\n' "$*" >&2; }

"$CONTAINER_BIN" network inspect "$NETWORK" >/dev/null 2>&1 \
  || "$CONTAINER_BIN" network create "$NETWORK" >/dev/null

"$CONTAINER_BIN" delete -f "$NAME" >/dev/null 2>&1 || true

"$CONTAINER_BIN" run -d --name "$NAME" --network "$NETWORK" --cap-add SYS_ADMIN \
  docker.io/library/alpine:3.20 \
  sh -c "
    set -e
    # Retry apk: early boot can race guest DNS (hosts-dns) before upstream resolves.
    # On TLS/CA flakes, rewrite Alpine repos to http and retry once more.
    ok=0
    for _ in \$(seq 1 60); do
      if apk add --no-cache nfs-utils rpcbind >/tmp/apk.log 2>&1; then
        ok=1
        break
      fi
      if grep -qi 'certificate verify failed\\|SSL routines' /tmp/apk.log 2>/dev/null; then
        sed -i 's|https://|http://|g' /etc/apk/repositories 2>/dev/null || true
        if apk add --no-cache nfs-utils rpcbind >/tmp/apk.log 2>&1; then
          ok=1
          break
        fi
      fi
      sleep 1
    done
    if [ \"\$ok\" -ne 1 ]; then
      echo APK_FAILED >&2
      cat /tmp/apk.log >&2 || true
      exit 1
    fi
    mkdir -p ${EXPORT_PATH} /proc/fs/nfsd /var/lib/nfs/v4recovery
    echo nfs-parity-ok > ${EXPORT_PATH}/hello.txt
    echo '${EXPORT_PATH} *(rw,sync,no_subtree_check,insecure,no_root_squash)' > /etc/exports
    mount -t nfsd nfsd /proc/fs/nfsd
    rpcbind -w
    exportfs -rav
    rpc.nfsd 8
    rpc.mountd
    command -v rpc.nfsd >/dev/null
    command -v rpc.mountd >/dev/null
    echo SERVER_READY
    sleep 3600" >/dev/null

ready=0
for _ in $(seq 1 120); do
  if "$CONTAINER_BIN" logs "$NAME" 2>/dev/null | grep -q SERVER_READY; then
    ready=1
    break
  fi
  if "$CONTAINER_BIN" logs "$NAME" 2>/dev/null | grep -q APK_FAILED; then
    log "nfs guest apk failed; see container logs for ${NAME}"
    "$CONTAINER_BIN" logs "$NAME" >&2 || true
    exit 1
  fi
  sleep 1
done
if [[ "${ready}" -ne 1 ]]; then
  log "timed out waiting for SERVER_READY from ${NAME}"
  "$CONTAINER_BIN" logs "$NAME" >&2 || true
  exit 1
fi

IP="$("$CONTAINER_BIN" inspect "$NAME" 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["status"]["networks"][0]["ipv4Address"].split("/")[0])')"
log "server=${NAME} network=${NETWORK} addr=${IP} export=${EXPORT_PATH}"
printf 'export COMPOSE_NFS_SERVER=%s\n' "$IP"
printf 'export COMPOSE_NFS_EXPORT=%s\n' "$EXPORT_PATH"
printf 'export NFS_TEST_NETWORK=%s\n' "$NETWORK"
