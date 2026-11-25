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

# R1: VZ live NIC hotplug surface (spare slots + RuntimeService VZ path).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VF="${ROOT}/../virtualization.framework"
fail() { printf '[f4-vz] FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf '[f4-vz] %s\n' "$*"; }

VZ="${VF}/Vendor/containerization/Sources/Containerization/VZVirtualMachineInstance.swift"
[[ -f "$VZ" ]] || fail "missing Vendor VZVirtualMachineInstance"
grep -q 'nicSpares' "$VZ" || fail "nicSpares missing"
grep -q 'Live-attach a network interface' "$VZ" || fail "VZ hotplugNetwork missing"
grep -q 'CONTAINER_VZ_NIC_SPARES' "$VZ" || fail "CONTAINER_VZ_NIC_SPARES missing"
RS="${ROOT}/Sources/Services/RuntimeLinux/Server/RuntimeService.swift"
grep -q 'VZVirtualMachineInstance' "$RS" || fail "RuntimeService missing VZ hotplug branch"
CS="${ROOT}/Sources/Services/ContainerAPIService/Server/Containers/ContainersService.swift"
grep -q 'Default \*\*on\*\* for CR and VZ' "$CS" || fail "ContainersService still disables VZ hotplug"
ok "F4_VZ_NET_HOTPLUG_OK"
