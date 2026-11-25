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

import Foundation
import NIO

public struct SocketForwarderResult: Sendable {
    private let channel: any Channel
    private let closeState: CloseState

    private final class CloseState: @unchecked Sendable {
        private let lock = NSLock()
        private var closed = false
        func markClosed() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if closed { return false }
            closed = true
            return true
        }
    }

    public init(channel: Channel) {
        self.channel = channel
        self.closeState = CloseState()
    }

    public var proxyAddress: SocketAddress? { self.channel.localAddress }

    public func close() {
        guard closeState.markClosed() else { return }
        // Only close while the channel reports active. Closing an already-torn-down
        // listen FD races with EventLoopGroup shutdown and can EBADF-trap in Posix.close.
        guard channel.isActive else { return }
        channel.close(mode: .all, promise: nil)
    }

    public func wait() async throws {
        // Always await closeFuture so callers that close() then wait() still
        // observe full teardown (isActive may already be false).
        try await channel.closeFuture.get()
    }
}
