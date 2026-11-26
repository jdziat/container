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

import Foundation

/// Narrowing and adjusting a plan before `up` starts anything. All pure, so it is unit-tested
/// without a container system.
extension ComposePlanner.Plan {
    /// Replicas above this are capped (the engine's existing interim limit).
    static let maxReplicas = 3

    /// Only `names` (and, unless `withDependencies` is false, everything they transitively depend on),
    /// in the plan's existing dependency order. With no names the plan is unchanged.
    ///
    /// Under `--no-deps` a kept service's `depends_on` entries for services that were not kept are
    /// dropped, so `up` does not go looking for (and waiting on) containers it was told not to start.
    func selecting(_ names: [String], withDependencies: Bool) throws -> ComposePlanner.Plan {
        guard !names.isEmpty else { return self }
        let known = Set(services.map(\.name))
        var wanted = Set<String>()
        var pending: [String] = []
        for name in names {
            guard known.contains(name) else {
                let hint = declaredServices.contains(name) ? " (declared, but its profile is not active; add --profile)" : ""
                throw ComposeError.invalid("no such service: \(name)\(hint)")
            }
            if wanted.insert(name).inserted { pending.append(name) }
        }
        if withDependencies {
            while let current = pending.popLast() {
                guard let service = services.first(where: { $0.name == current }) else { continue }
                for dependency in service.dependsOn where known.contains(dependency.service) {
                    if wanted.insert(dependency.service).inserted { pending.append(dependency.service) }
                }
            }
        }
        var narrowed = self
        narrowed.services = services.filter { wanted.contains($0.name) }.map { service in
            var kept = service
            kept.dependsOn = service.dependsOn.filter { wanted.contains($0.service) }
            return kept
        }
        return narrowed
    }

    /// `--scale SERVICE=N` (repeatable). N must be at least 1 and is capped at ``maxReplicas`` with a warning.
    func scaled(_ specs: [String]) throws -> ComposePlanner.Plan {
        guard !specs.isEmpty else { return self }
        var result = self
        for spec in specs {
            let parts = spec.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, let requested = Int(parts[1]), requested >= 1 else {
                throw ComposeError.invalid("--scale expects SERVICE=N with N >= 1, got '\(spec)'")
            }
            guard let index = result.services.firstIndex(where: { $0.name == parts[0] }) else {
                throw ComposeError.invalid("--scale: no such service: \(parts[0])")
            }
            var count = requested
            if count > Self.maxReplicas {
                let warning = "service \(parts[0]): --scale \(requested) capped at \(Self.maxReplicas)"
                result.warnings.append(warning)
                FileHandle.standardError.write(Data("WARN: \(warning)\n".utf8))
                count = Self.maxReplicas
            }
            result.services[index].replicas = count
        }
        return result
    }

    /// `up --pull always|missing|never`: replaces every selected service's `pull_policy`.
    func overridingPullPolicy(_ value: String) throws -> ComposePlanner.Plan {
        let policy: ServiceOptions.PullPolicy
        switch value.lowercased() {
        case "always": policy = .always
        case "missing", "if_not_present": policy = .missing
        case "never": policy = .never
        default: throw ComposeError.invalid("--pull must be always, missing or never, got '\(value)'")
        }
        var result = self
        for index in result.services.indices { result.services[index].options.pullPolicy = policy }
        return result
    }
}
