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

import ContainerResource
import Testing

struct ContainerEventBusTests {
    @Test
    func publishesAndReturnsBufferedEvents() async {
        let bus = ContainerEventBus(capacity: 8)
        _ = await bus.publish(status: "create", action: "create", actorID: "a")
        let second = await bus.publish(status: "start", action: "start", actorID: "a")
        let batch = await bus.next(since: 0)
        #expect(batch.count == 2)
        #expect(batch.last?.id == second.id)
        #expect(batch.last?.action == "start")
    }

    @Test
    func nextWaitsUntilPublish() async {
        let bus = ContainerEventBus(capacity: 8)
        async let waiting = bus.next(since: 0)
        try? await Task.sleep(for: .milliseconds(50))
        let published = await bus.publish(status: "die", action: "die", actorID: "b")
        let batch = await waiting
        #expect(batch.count == 1)
        #expect(batch[0].id == published.id)
    }

    /// An idle long-poll must return empty on the server's own timeout, and must not leave its
    /// waiter behind: a client that times out on its side would otherwise leak one per poll.
    @Test
    func timedOutWaitReturnsEmptyAndRemovesItsWaiter() async {
        let bus = ContainerEventBus(capacity: 8)
        let started = ContinuousClock.now
        let batch = await bus.next(since: 0, timeout: .milliseconds(100))
        #expect(batch.isEmpty)
        #expect(ContinuousClock.now - started >= .milliseconds(90))
        // The expired waiter must be gone: a later publish must not resume anything twice
        // (resuming a continuation twice is a crash), and a fresh wait must still work.
        async let waiting = bus.next(since: 0, timeout: .seconds(5))
        try? await Task.sleep(for: .milliseconds(50))
        let published = await bus.publish(status: "start", action: "start", actorID: "c")
        let next = await waiting
        #expect(next.map(\.id) == [published.id])
    }

    @Test
    func publishBeatsTheTimeout() async {
        let bus = ContainerEventBus(capacity: 8)
        async let waiting = bus.next(since: 0, timeout: .milliseconds(200))
        try? await Task.sleep(for: .milliseconds(30))
        _ = await bus.publish(status: "die", action: "die", actorID: "d")
        // Outlive the timeout: the stale sleeper must not double-resume the continuation.
        try? await Task.sleep(for: .milliseconds(300))
        #expect((await waiting).count == 1)
    }
}
