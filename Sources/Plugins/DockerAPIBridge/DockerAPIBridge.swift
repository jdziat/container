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

import ArgumentParser
import Foundation
import Logging

@main
struct DockerAPIBridge: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "docker-api-bridge",
        abstract: "Optional Docker Engine API compatibility bridge (plugin path; not in-core)",
        subcommands: [Serve.self, Support.self],
        defaultSubcommand: Serve.self
    )
}

extension DockerAPIBridge {
    struct Serve: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Serve a curated Docker Engine API subset over a Unix socket"
        )

        @Option(
            name: .customLong("socket"),
            help:
                "Unix socket path (DOCKER_HOST=unix://<path>). May be /var/run/docker.sock if you can bind it (typically root); the bridge chmods the socket to 0600. Overridden by CONTAINER_ENGINE_SOCK when set."
        )
        var socket: String = DockerAPIBridgeServer.defaultSocketPath

        @Flag(
            name: .customLong("privileged-sock"),
            help: "Bind /var/run/docker.sock (Recipe B; same as CONTAINER_ENGINE_SOCK=/var/run/docker.sock)"
        )
        var privilegedSock = false

        func run() async throws {
            var logger = Logger(label: "com.apple.container.docker-api-bridge")
            logger.logLevel = .info
            var path = socket
            if let env = ProcessInfo.processInfo.environment["CONTAINER_ENGINE_SOCK"],
                !env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                path = env.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if privilegedSock {
                path = "/var/run/docker.sock"
            }
            if path == "/var/run/docker.sock" {
                FileHandle.standardError.write(
                    Data(
                        "warning: binding /var/run/docker.sock requires privilege to create that path; socket mode will be 0600 (Recipe B: scripts/install-engine-sock.sh)\n"
                            .utf8
                    )
                )
            }
            let server = DockerAPIBridgeServer(socketPath: path, log: logger)
            FileHandle.standardError.write(
                Data(
                    "docker-api-bridge listening on unix://\(path)\nSet DOCKER_HOST=unix://\(path)\n"
                        .utf8
                )
            )
            try await server.run()
        }
    }

    struct Support: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print the supported Engine API route matrix"
        )

        func run() {
            print(DockerAPIBridgeServer.supportMatrix)
        }
    }
}

