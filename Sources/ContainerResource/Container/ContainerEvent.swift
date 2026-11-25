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

/// A Docker-shaped lifecycle event emitted by the API server.
public struct ContainerEvent: Codable, Sendable, Equatable {
    public var id: UInt64
    public var status: String
    public var type: String
    public var action: String
    public var actorID: String
    public var actorAttributes: [String: String]
    public var time: Int64
    public var timeNano: Int64

    public init(
        id: UInt64,
        status: String,
        type: String = "container",
        action: String,
        actorID: String,
        actorAttributes: [String: String] = [:],
        time: Date = Date()
    ) {
        self.id = id
        self.status = status
        self.type = type
        self.action = action
        self.actorID = actorID
        self.actorAttributes = actorAttributes
        let seconds = Int64(time.timeIntervalSince1970)
        self.time = seconds
        self.timeNano = Int64(time.timeIntervalSince1970 * 1_000_000_000)
    }
}

/// In-memory fan-out of container lifecycle events for `container events`.
public actor ContainerEventBus {
    private var nextID: UInt64 = 1
    private var buffer: [ContainerEvent] = []
    private let capacity: Int
    private var waiters: [UUID: (since: UInt64, cont: CheckedContinuation<[ContainerEvent], Never>)] = [:]

    public init(capacity: Int = 1024) {
        self.capacity = capacity
    }

    @discardableResult
    public func publish(
        status: String,
        action: String,
        actorID: String,
        attributes: [String: String] = [:]
    ) -> ContainerEvent {
        let event = ContainerEvent(
            id: nextID,
            status: status,
            action: action,
            actorID: actorID,
            actorAttributes: attributes
        )
        nextID += 1
        buffer.append(event)
        if buffer.count > capacity {
            buffer.removeFirst(buffer.count - capacity)
        }
        for (waiterID, waiter) in waiters {
            let matching = buffer.filter { $0.id > waiter.since }
            guard !matching.isEmpty else { continue }
            waiters.removeValue(forKey: waiterID)
            waiter.cont.resume(returning: matching)
        }
        return event
    }

    /// Like ``next(since:)`` but gives up after `timeout`, returning `[]` and removing its own
    /// waiter. A long-poll client that times out on its side must not leave a waiter behind in
    /// the server: those accumulate without bound on an idle event stream.
    public func next(since: UInt64, timeout: Duration) async -> [ContainerEvent] {
        let pending = buffer.filter { $0.id > since }
        if !pending.isEmpty { return pending }
        let key = UUID()
        return await withCheckedContinuation { cont in
            waiters[key] = (since, cont)
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.expireWaiter(key)
            }
        }
    }

    private func expireWaiter(_ key: UUID) {
        if let waiter = waiters.removeValue(forKey: key) { waiter.cont.resume(returning: []) }
    }

    /// Returns events with `id > since`. If none are buffered, waits until the next matching publish.
    public func next(since: UInt64) async -> [ContainerEvent] {
        let pending = buffer.filter { $0.id > since }
        if !pending.isEmpty {
            return pending
        }
        return await withCheckedContinuation { cont in
            waiters[UUID()] = (since, cont)
        }
    }
}
