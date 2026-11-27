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

# Run a command with a wall-clock limit and kill its whole process tree when it expires.
# macOS has no `timeout`, and a parity harness that hangs (one `container network create` once
# blocked for 47 minutes) must fail with a message, not sit there until the job's limit.
#
#   with-timeout.sh SECONDS command [args...]     exit 124 on timeout, else the command's own status
set -u
limit="${1:?usage: with-timeout.sh SECONDS command [args...]}"
shift

descendants() {
  local pid
  for pid in $(pgrep -P "$1" 2>/dev/null); do
    descendants "${pid}"
    echo "${pid}"
  done
}

# The watchdog tells this process it fired (SIGUSR1) before it kills anything, so the exit status does not
# depend on a race between the child dying and the watchdog finishing.
timed_out=0
trap 'timed_out=1' USR1
parent=$$

"$@" &
child=$!
(
  sleep "${limit}"
  if kill -0 "${child}" 2>/dev/null; then
    kill -USR1 "${parent}" 2>/dev/null
    echo "with-timeout: '$*' exceeded ${limit}s; killing it and its children" >&2
    # Children first, so they cannot be re-parented and outlive the kill.
    # shellcheck disable=SC2046
    kill -TERM $(descendants "${child}") "${child}" 2>/dev/null
    sleep 3
    # shellcheck disable=SC2046
    kill -KILL $(descendants "${child}") "${child}" 2>/dev/null
  fi
) &
watchdog=$!

# Always collect the status with `wait`: bash reaps a finished child by itself, so probing it with `kill -0`
# first can miss it and lose the exit code. `wait` also returns early (status > 128) when the USR1 above
# arrives while the child still runs, so wait again until the child is really gone.
wait "${child}"
status=$?
while [[ "${status}" -ge 128 ]] && kill -0 "${child}" 2>/dev/null; do
  wait "${child}"
  status=$?
done
kill "${watchdog}" 2>/dev/null
wait "${watchdog}" 2>/dev/null
[[ "${timed_out}" == 1 ]] && exit 124
exit "${status}"
