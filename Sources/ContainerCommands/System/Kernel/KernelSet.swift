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

import ArgumentParser
import ContainerAPIClient
import ContainerPersistence
import ContainerPlugin
import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import Logging
import TerminalProgress

extension Application {
    public struct KernelSet: AsyncLoggableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "Set the default kernel"
        )

        @Option(name: .long, help: "The architecture of the kernel binary (values: amd64, arm64)")
        var arch: String = ContainerizationOCI.Platform.current.architecture.description

        @Option(name: .customLong("binary"), help: "Path to the kernel file (or archive member, if used with --tar)")
        var binaryPath: String? = nil

        @Flag(name: .long, help: "Overwrites an existing kernel with the same name")
        var force: Bool = false

        @Flag(
            name: .long,
            help: ArgumentHelp(
                "Install the preferred default kernel (takes precedence over all other flags). "
                    + "When CONTAINER_PREFERRED_KERNEL is unset or nfs (default), runs the NFS-capable "
                    + "install path (`make install-nfs-kernel` / install-recommended-kernel). "
                    + "Set CONTAINER_PREFERRED_KERNEL=kata for the historic Kata tarball."
            )
        )
        var recommended: Bool = false

        @Option(name: .customLong("tar"), help: "Filesystem path or remote URL to a tar archive containing a kernel file")
        var tarPath: String? = nil

        @Option(name: .long, help: "Expected digest for the tar archive, for example sha256:<hex>. Required when --tar is a remote URL.")
        var digest: String? = nil

        @OptionGroup
        public var logOptions: Flags.Logging

        public init() {}

        public func run() async throws {
            if recommended {
                let preference = Self.preferredKernelPreference()
                if Self.prefersNFSCapableKernel(preference) {
                    log.info(
                        "Preferred kernel is NFS-capable (CONTAINER_PREFERRED_KERNEL=\(preference)). Installing via install-nfs-kernel / install-recommended-kernel..."
                    )
                    try await Self.installPreferredNFSKernel(force: force, log: log)
                    return
                }
                let containerSystemConfig: ContainerSystemConfig = try await ClientHealthCheck.loadContainerSystemConfig()
                let url = containerSystemConfig.kernel.url
                let path: String = containerSystemConfig.kernel.binaryPath
                log.info("Installing the Kata recommended kernel from \(url) (CONTAINER_PREFERRED_KERNEL=\(preference))...")
                try await Self.downloadAndInstallWithProgressBar(
                    tarRemoteURL: url,
                    kernelFilePath: path,
                    expectedDigest: containerSystemConfig.kernel.digest,
                    force: force)
                return
            }
            guard tarPath != nil else {
                return try await self.setKernelFromBinary()
            }
            try await self.setKernelFromTar()
        }

        private func setKernelFromBinary() async throws {
            guard digest == nil else {
                throw ArgumentParser.ValidationError("'--digest' can only be used with '--tar'")
            }
            guard let binaryPath else {
                throw ArgumentParser.ValidationError("missing argument '--binary'")
            }
            let absolutePath = URL(fileURLWithPath: binaryPath, relativeTo: .currentDirectory()).absoluteURL.absoluteString
            let platform = try getSystemPlatform()
            try await ClientKernel.installKernel(kernelFilePath: absolutePath, platform: platform, force: force)
        }

        private func setKernelFromTar() async throws {
            guard let binaryPath else {
                throw ArgumentParser.ValidationError("missing argument '--binary'")
            }
            guard let tarPath else {
                throw ArgumentParser.ValidationError("missing argument '--tar")
            }
            let platform = try getSystemPlatform()
            let remoteURL = URL(string: tarPath)
            let remoteScheme = remoteURL?.scheme?.lowercased()
            let isHTTPURL = remoteScheme == "http" || remoteScheme == "https"
            let localTarPath = URL(fileURLWithPath: tarPath, relativeTo: .currentDirectory()).path
            let fm = FileManager.default
            if !isHTTPURL && fm.fileExists(atPath: localTarPath) {
                try await ClientKernel.installKernelFromTar(
                    tarFile: localTarPath,
                    kernelFilePath: binaryPath,
                    platform: platform,
                    expectedDigest: digest,
                    force: force)
                return
            }
            guard let remoteURL else {
                throw ContainerizationError(.invalidArgument, message: "invalid remote URL '\(tarPath)' for argument '--tar'. Missing protocol?")
            }
            guard let digest else {
                throw ArgumentParser.ValidationError("'--digest' is required when '--tar' is a remote URL")
            }
            try await Self.downloadAndInstallWithProgressBar(
                tarRemoteURL: remoteURL,
                kernelFilePath: binaryPath,
                platform: platform,
                expectedDigest: digest,
                force: force)
        }

        private func getSystemPlatform() throws -> SystemPlatform {
            switch arch {
            case "arm64":
                return .linuxArm
            case "amd64":
                return .linuxAmd
            default:
                throw ContainerizationError(.unsupported, message: "unsupported architecture \(arch)")
            }
        }

        static func downloadAndInstallWithProgressBar(
            tarRemoteURL: URL,
            kernelFilePath: String,
            platform: SystemPlatform = .current,
            expectedDigest: String,
            force: Bool
        ) async throws {
            let progressConfig = try ProgressConfig(
                showTasks: true,
                totalTasks: 3
            )
            let progress = ProgressBar(config: progressConfig)
            defer {
                progress.finish()
            }
            progress.start()
            try await ClientKernel.installKernelFromTar(
                tarFile: tarRemoteURL.absoluteString,
                kernelFilePath: kernelFilePath,
                platform: platform,
                progressUpdate: progress.handler,
                expectedDigest: expectedDigest,
                force: force)
            progress.finish()
        }

        /// Default preference is `nfs` (stock path for NFS / Compose users).
        static func preferredKernelPreference() -> String {
            let raw = ProcessInfo.processInfo.environment["CONTAINER_PREFERRED_KERNEL"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard let raw, !raw.isEmpty else { return "nfs" }
            return raw
        }

        static func prefersNFSCapableKernel(_ preference: String = preferredKernelPreference()) -> Bool {
            preference == "nfs"
        }

        /// Locate install-recommended-kernel / install-nfs-kernel helpers next to the CLI or in a repo checkout.
        static func locatePreferredKernelInstaller() -> URL? {
            let fm = FileManager.default
            var dirs: [URL] = []
            let argv0 = URL(fileURLWithPath: CommandLine.arguments[0])
            dirs.append(argv0.deletingLastPathComponent())
            let resolved = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            dirs.append(resolved.deletingLastPathComponent())
            dirs.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            dirs.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("scripts"))
            dirs.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("bin"))

            let names = [
                "install-recommended-kernel.sh",
                "install-container-recommended-kernel",
                "install-nfs-kernel.sh",
                "install-container-nfs-kernel",
            ]
            for dir in dirs {
                for name in names {
                    let candidate = dir.appendingPathComponent(name)
                    if fm.isExecutableFile(atPath: candidate.path) || fm.fileExists(atPath: candidate.path) {
                        return candidate
                    }
                }
                // Repo layout: <checkout>/bin/container → <checkout>/scripts/...
                let siblingScripts = dir.deletingLastPathComponent().appendingPathComponent("scripts")
                for name in ["install-recommended-kernel.sh", "install-nfs-kernel.sh"] {
                    let candidate = siblingScripts.appendingPathComponent(name)
                    if fm.isExecutableFile(atPath: candidate.path) || fm.fileExists(atPath: candidate.path) {
                        return candidate
                    }
                }
            }
            return nil
        }

        static func installPreferredNFSKernel(force: Bool, log: Logger) async throws {
            let instructions =
                "NFS-capable kernel is the stock preferred path. Run: "
                + "`make install-recommended-kernel` or `make install-nfs-kernel` "
                + "(or `install-container-nfs-kernel` / `scripts/install-nfs-kernel.sh`). "
                + "Set CONTAINER_PREFERRED_KERNEL=kata to use the historic Kata --recommended tarball. "
                + "See docs/volumes.md#nfs-mounts."

            guard let installer = locatePreferredKernelInstaller() else {
                log.error("\(instructions)")
                throw ContainerizationError(.notFound, message: instructions)
            }

            log.info("Invoking \(installer.path)...")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [installer.path]
            var env = ProcessInfo.processInfo.environment
            env["CONTAINER_PREFERRED_KERNEL"] = "nfs"
            // install-nfs-kernel.sh reads FORCE (default 1).
            env["FORCE"] = force ? "1" : "0"
            if env["CONTAINER_BIN"] == nil {
                env["CONTAINER_BIN"] = CommandLine.arguments[0]
            }
            process.environment = env
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError

            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw ContainerizationError(
                    .internalError,
                    message:
                        "preferred NFS kernel install failed (exit \(process.terminationStatus)). \(instructions)"
                )
            }
        }

    }
}
