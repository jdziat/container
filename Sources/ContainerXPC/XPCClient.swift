//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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

#if os(macOS)
import ContainerizationError
import Foundation

public final class XPCClient: Sendable {
    /// The maximum amount of time to wait for a request to a recently
    /// registered XPC service. Once a service has launched, XPC
    /// requests only have milliseconds of overhead, but in some instances,
    /// macOS can take 5 seconds (or considerably longer) to launch a
    /// service after it has been registered.
    public static let xpcRegistrationTimeout: Duration = .seconds(60)

    private nonisolated(unsafe) let connection: xpc_connection_t
    private let q: DispatchQueue?
    private let service: String

    public init(service: String, queue: DispatchQueue? = nil) {
        let connection = xpc_connection_create_mach_service(service, queue, 0)
        self.connection = connection
        self.q = queue
        self.service = service

        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_set_target_queue(connection, self.q)
        xpc_connection_activate(connection)
    }

    public init(connection: xpc_connection_t, label: String, queue: DispatchQueue? = nil) {
        self.connection = connection
        self.q = queue
        self.service = label

        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_set_target_queue(connection, self.q)
        xpc_connection_activate(connection)
    }

    deinit {
        self.close()
    }
}

extension XPCClient {
    /// Close the underlying XPC connection.
    public func close() {
        xpc_connection_cancel(connection)
    }

    /// Returns the pid of process to which we have a connection.
    /// Note: `xpc_connection_get_pid` returns 0 if no activity
    /// has taken place on the connection prior to it being called.
    public func remotePid() -> pid_t {
        xpc_connection_get_pid(self.connection)
    }

    /// Install a handler that is called whenever the connection receives an XPC error event.
    ///
    /// This replaces the existing (no-op) event handler. Call this before the first
    /// `send()` to avoid a disconnect-before-handler race.
    ///
    /// ```swift
    /// let client = XPCClient(service: "com.example.myservice")
    /// client.setDisconnectHandler {
    ///     print("service disconnected, cleaning up")
    /// }
    /// let response = try await client.send(request)
    /// ```
    public func setDisconnectHandler(_ handler: @Sendable @escaping () -> Void) {
        xpc_connection_set_event_handler(connection) { object in
            if xpc_get_type(object) == XPC_TYPE_ERROR { handler() }
        }
    }

    /// Create a persistent session backed by this client connection.
    ///
    /// The session installs a disconnect handler at initialisation time, before
    /// any messages are sent, ensuring no server-exit event is missed.
    public func openSession() -> XPCClientSession {
        XPCClientSession(client: self)
    }

    /// Send the provided message to the service.
    ///
    /// With a `responseTimeout`, this throws if the service has not replied in time, even when it never replies.
    /// That used to be a task group racing the reply against a sleep, but the reply side is a continuation, which
    /// cannot be cancelled: when the sleep won, the group still waited for the reply, so a service that never
    /// answered (a helper stuck restarting) made the timeout itself hang. This resumes ONE continuation from
    /// whichever finishes first and ignores the other.
    @discardableResult
    public func send(_ message: XPCMessage, responseTimeout: Duration? = nil) async throws -> XPCMessage {
        let race = ReplyRace()
        let service = self.service
        let route = message.string(key: XPCMessage.routeKey) ?? "nil"
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<XPCMessage, Error>) in
            race.install(continuation)
            if let responseTimeout {
                let timer = Task {
                    do { try await Task.sleep(for: responseTimeout) } catch { return }  // cancelled: a reply won
                    race.finish(
                        .failure(
                            ContainerizationError(
                                .internalError,
                                message: "XPC timeout for request to \(service)/\(route)"
                            )))
                }
                race.setTimer(timer)
            }
            xpc_connection_send_message_with_reply(self.connection, message.underlying, nil) { reply in
                do {
                    race.finish(.success(try self.parseReply(reply)))
                } catch {
                    race.finish(.failure(error))
                }
            }
        }
    }

    private func parseReply(_ reply: xpc_object_t) throws -> XPCMessage {
        switch xpc_get_type(reply) {
        case XPC_TYPE_ERROR:
            var code = ContainerizationError.Code.invalidState
            if reply.connectionError {
                code = .interrupted
            }
            throw ContainerizationError(
                code,
                message: "XPC connection error: \(reply.errorDescription ?? "unknown")"
            )
        case XPC_TYPE_DICTIONARY:
            let message = XPCMessage(object: reply)
            // check errors from our protocol
            try message.error()
            return message
        default:
            fatalError("unhandled xpc object type: \(xpc_get_type(reply))")
        }
    }
}

/// Resumes a continuation at most once, from either the XPC reply or the timeout, and cancels the timer when a
/// reply wins so it does not linger for the whole timeout.
private final class ReplyRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<XPCMessage, Error>?
    private var timer: Task<Void, Never>?
    /// Set once the race is decided, so a timer registered after that is cancelled instead of left sleeping.
    private var finished = false

    func install(_ continuation: CheckedContinuation<XPCMessage, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func setTimer(_ timer: Task<Void, Never>) {
        lock.lock()
        if finished {
            lock.unlock()
            timer.cancel()
            return
        }
        self.timer = timer
        lock.unlock()
    }

    func finish(_ result: Result<XPCMessage, Error>) {
        lock.lock()
        // The continuation is the once-only guard: it is cleared before it is resumed, so the loser of the race
        // (a late reply after a timeout, or a late timeout after a reply) finds nothing to resume.
        guard let continuation else {
            lock.unlock()
            return
        }
        finished = true
        self.continuation = nil
        let timer = self.timer
        self.timer = nil
        lock.unlock()
        timer?.cancel()
        continuation.resume(with: result)
    }
}

#endif
