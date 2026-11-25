#!/usr/bin/env bash
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
