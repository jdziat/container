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

#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import SwiftUI
import ContainerAPIClient
import ContainerResource

@main
struct ContainerGUIApp: App {
    var body: some Scene {
        WindowGroup("Container") {
            ContentView()
                .frame(minWidth: 900, minHeight: 520)
        }
    }
}

@MainActor
final class ContainerStore: ObservableObject {
    @Published var rows: [ContainerSnapshot] = []
    @Published var selectedID: String?
    @Published var logText: String = ""
    @Published var errorText: String?
    @Published var busy = false
    @Published var framebufferHosted = false

    private let client = ContainerClient()

    func refresh() async {
        busy = true
        defer { busy = false }
        do {
            rows = try await client.list()
            errorText = nil
            if let selectedID, !rows.contains(where: { $0.id == selectedID }) {
                self.selectedID = nil
                logText = ""
                framebufferHosted = false
            }
        } catch {
            errorText = String(describing: error)
        }
    }

    func select(_ id: String) async {
        selectedID = id
        await loadLogs(id)
        if let row = rows.first(where: { $0.id == id }),
            row.configuration.labels["gui.framebuffer"] == "1"
                || row.configuration.labels["com.apple.container.gpu"] == "1"
        {
            framebufferHosted = true
        } else {
            framebufferHosted = false
        }
    }

    func loadLogs(_ id: String) async {
        do {
            let handles = try await client.logs(id: id)
            var chunks: [String] = []
            for handle in handles {
                let data = handle.readDataToEndOfFile()
                if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                    chunks.append(text)
                }
            }
            logText = chunks.joined(separator: "\n---\n")
            if logText.isEmpty { logText = "(no log output yet)" }
            errorText = nil
        } catch {
            logText = ""
            errorText = String(describing: error)
        }
    }

    func start(_ id: String) async {
        busy = true
        defer { busy = false }
        do {
            _ = try await client.bootstrap(id: id, stdio: [nil, nil, nil])
            let proc = client.initProcess(id: id)
            try await proc.start()
            await refresh()
            await select(id)
        } catch {
            errorText = String(describing: error)
        }
    }

    func stop(_ id: String) async {
        busy = true
        defer { busy = false }
        do {
            try await client.stop(id: id)
            await refresh()
        } catch {
            errorText = String(describing: error)
        }
    }

    func delete(_ id: String) async {
        busy = true
        defer { busy = false }
        do {
            try await client.delete(id: id, force: true)
            await refresh()
        } catch {
            errorText = String(describing: error)
        }
    }
}

struct ContentView: View {
    @StateObject private var store = ContainerStore()

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Containers")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Button("Refresh") { Task { await store.refresh() } }
                        .disabled(store.busy)
                }
                if let err = store.errorText {
                    Text(err)
                        .foregroundStyle(.red)
                        .font(.caption)
                        .textSelection(.enabled)
                }
                List(store.rows, id: \.id, selection: $store.selectedID) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.configuration.name).font(.body.weight(.medium))
                        Text(row.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text(String(describing: row.status)).font(.caption2)
                    }
                    .tag(row.id)
                    .contentShape(Rectangle())
                    .onTapGesture { Task { await store.select(row.id) } }
                }
                if let id = store.selectedID {
                    HStack {
                        Button("Start") { Task { await store.start(id) } }
                        Button("Stop") { Task { await store.stop(id) } }
                        Button("Delete", role: .destructive) { Task { await store.delete(id) } }
                        Button("Logs") { Task { await store.loadLogs(id) } }
                    }
                    .disabled(store.busy)
                }
            }
            .padding()
            .frame(minWidth: 320)

            VStack(alignment: .leading, spacing: 8) {
                Text("Logs").font(.headline)
                ScrollView {
                    Text(store.logText.isEmpty ? "Select a container to view logs." : store.logText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .background(Color.secondary.opacity(0.08))
                Divider()
                Text("Framebuffer").font(.headline)
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.black)
                        .frame(minHeight: 160)
                    if store.framebufferHosted {
                        Text("Framebuffer host is not implemented (container flagged for GPU/framebuffer)")
                            .foregroundStyle(.green)
                            .font(.caption)
                    } else {
                        Text("No GPU framebuffer for selection")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
                Text("container-gui — list / start / stop / delete / logs. No framebuffer host yet.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(minWidth: 400)
        }
        .task { await store.refresh() }
    }
}
#else
@main
enum ContainerGUIMain {
    static func main() {
        fputs("ContainerGUI requires AppKit/SwiftUI on macOS.\n", stderr)
        exit(1)
    }
}
#endif
