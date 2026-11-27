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

@preconcurrency import ContainerXPC
import Foundation
import Testing

/// `XPCClient.send(_:responseTimeout:)` must give up when the peer never replies. It used to race the reply
/// against a timeout in a task group, but the reply side is a continuation that ignores cancellation, so when
/// the timeout won the group still waited for the reply forever and the timeout error was never delivered. A
/// network helper that could not start (vmnet failing, launchd restarting it) then hung the whole apiserver.
struct XPCClientTimeoutTests {
    private final class Peer: @unchecked Sendable {
        nonisolated(unsafe) let listener: xpc_connection_t
        nonisolated(unsafe) var clientConnection: xpc_connection_t!
        private let queue = DispatchQueue(label: "xpc-timeout-test-peer")
        private var received = 0
        private let lock = NSLock()
        private var held: [xpc_connection_t] = []
        private var heldMessages: [xpc_object_t] = []

        /// A peer that reads every message and answers `replyAfter` seconds later, or never when nil.
        init(replyAfter: Double?) {
            listener = xpc_connection_create(nil, queue)
            clientConnection = nil
            xpc_connection_set_event_handler(listener) { [weak self] peer in
                guard let self, xpc_get_type(peer) == XPC_TYPE_CONNECTION else { return }
                self.lock.lock()
                self.held.append(peer)  // keep the connection alive so the client sees silence, not a hang-up
                self.lock.unlock()
                xpc_connection_set_event_handler(peer) { [weak self] message in
                    guard let self, xpc_get_type(message) == XPC_TYPE_DICTIONARY else { return }
                    self.lock.lock()
                    self.received += 1
                    self.heldMessages.append(message)
                    self.lock.unlock()
                    guard let replyAfter else { return }
                    self.queue.asyncAfter(deadline: .now() + replyAfter) {
                        if let reply = xpc_dictionary_create_reply(message) {
                            xpc_dictionary_set_string(reply, "answer", "ok")
                            xpc_connection_send_message(peer, reply)
                        }
                    }
                }
                xpc_connection_activate(peer)
            }
            xpc_connection_activate(listener)
            clientConnection = xpc_connection_create_from_endpoint(xpc_endpoint_create(listener))
        }

        var messagesReceived: Int {
            lock.lock()
            defer { lock.unlock() }
            return received
        }
    }

    /// Resumes a continuation exactly once, from whichever of the work or the watchdog finishes first.
    private final class Once<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Result<T, Error>?, Never>?
        private var finished = false

        func install(_ continuation: CheckedContinuation<Result<T, Error>?, Never>) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }

        func finish(_ value: Result<T, Error>?) {
            lock.lock()
            guard !finished, let continuation else {
                lock.unlock()
                return
            }
            finished = true
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: value)
        }
    }

    /// Run `body`, but report nil instead of hanging if it takes longer than `limit` seconds.
    ///
    /// Deliberately NOT a task group: a group waits for every child before it returns, so a child that ignores
    /// cancellation (exactly the bug under test) would hang the watchdog too. The stuck work is simply left
    /// behind when the limit passes.
    private func withinLimit<T: Sendable>(_ limit: Double, _ body: @escaping @Sendable () async throws -> T) async -> Result<T, Error>? {
        let once = Once<T>()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Result<T, Error>?, Never>) in
            once.install(continuation)
            Task {
                do { once.finish(.success(try await body())) } catch { once.finish(.failure(error)) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + limit) { once.finish(nil) }
        }
    }

    @Test func aSilentPeerTimesOut() async {
        let peer = Peer(replyAfter: nil)
        let client = XPCClient(connection: peer.clientConnection, label: "silent")
        let started = ContinuousClock.now
        let outcome = await withinLimit(10) {
            try await client.send(XPCMessage(route: "status"), responseTimeout: .seconds(1))
        }
        let elapsed = ContinuousClock.now - started
        guard let outcome else {
            Issue.record("send() was still waiting after 10s: the timeout never fired")
            return
        }
        switch outcome {
        case .success:
            Issue.record("a peer that never replies must not produce a response")
        case .failure(let error):
            #expect("\(error)".contains("XPC timeout"), "unexpected error: \(error)")
        }
        #expect(elapsed < .seconds(5), "timed out after \(elapsed), expected about 1s")
        #expect(peer.messagesReceived == 1, "the request should have reached the peer once")
    }

    @Test func aPromptReplyIsReturnedAndTheTimeoutDoesNotFireLater() async throws {
        let peer = Peer(replyAfter: 0.1)
        let client = XPCClient(connection: peer.clientConnection, label: "prompt")
        let outcome = await withinLimit(10) {
            try await client.send(XPCMessage(route: "status"), responseTimeout: .seconds(2))
        }
        guard let outcome else {
            Issue.record("send() hung even though the peer replied")
            return
        }
        let response = try outcome.get()
        #expect(response.string(key: "answer") == "ok")
        // The abandoned timeout must not resume the continuation a second time (that would crash).
        try await Task.sleep(for: .seconds(2.5))
    }

    @Test func noTimeoutMeansWaitForTheReply() async throws {
        let peer = Peer(replyAfter: 0.5)
        let client = XPCClient(connection: peer.clientConnection, label: "slow")
        let outcome = await withinLimit(10) { try await client.send(XPCMessage(route: "status")) }
        guard let outcome else {
            Issue.record("send() hung even though the peer replied")
            return
        }
        #expect(try outcome.get().string(key: "answer") == "ok")
    }

    @Test func aReplyAfterTheTimeoutIsIgnored() async throws {
        let peer = Peer(replyAfter: 1.5)
        let client = XPCClient(connection: peer.clientConnection, label: "late")
        let outcome = await withinLimit(10) {
            try await client.send(XPCMessage(route: "status"), responseTimeout: .seconds(0.5))
        }
        guard let outcome else {
            Issue.record("send() was still waiting after 10s: the timeout never fired")
            return
        }
        if case .success = outcome { Issue.record("the reply came after the timeout and must not be returned") }
        // The late reply arrives now; it must be dropped, not resume the finished continuation (that would crash).
        try await Task.sleep(for: .seconds(2))
    }
}
