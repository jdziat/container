//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

/// Host→container device mapping (`--device` / Compose `devices:`).
///
/// R2: unrestricted by default. Char devices are shared via virtiofs file mounts;
/// block devices via virtio-blk. Set `CONTAINER_DEVICE_ALLOWLIST_ONLY=1` for the
/// legacy fail-closed allowlist.
public struct ContainerDevice: Sendable, Codable, Equatable {
    public var hostPath: String
    public var containerPath: String
    /// Optional Docker-shaped mode (`rwm`, `r`, …); recorded for inspect, not enforced.
    public var mode: String?

    public init(hostPath: String, containerPath: String, mode: String? = nil) {
        self.hostPath = hostPath
        self.containerPath = containerPath
        self.mode = mode
    }

    /// Short form for CLI / Compose (`HOST:CONTAINER` or `HOST:CONTAINER:MODE`).
    public var runSpec: String {
        if let mode, !mode.isEmpty {
            return "\(hostPath):\(containerPath):\(mode)"
        }
        if hostPath == containerPath {
            return hostPath
        }
        return "\(hostPath):\(containerPath)"
    }
}
