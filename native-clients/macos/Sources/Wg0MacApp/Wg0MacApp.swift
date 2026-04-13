import SwiftUI

@main
struct Wg0MacApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // Main dashboard window.
        WindowGroup("wg0") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 820, minHeight: 560)
        }
        .windowResizability(.contentSize)

        // Menu bar extra — always visible in the top bar.
        MenuBarExtra {
            MenuBarView()
                .environmentObject(model)
        } label: {
            Image(systemName: model.connectionState == .connected ? "shield.checkered" : "shield.slash")
        }
    }
}

// MARK: - Menu bar dropdown

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Status header
            HStack {
                Circle()
                    .fill(model.connectionState == .connected ? .green : .gray)
                    .frame(width: 8, height: 8)
                Text(model.connectionState == .connected ? "Connected" : "Disconnected")
                    .font(.headline)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)

            if let ip = model.enrolledOverlayIp {
                Text(ip)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.bottom, 6)
            }

            if model.tunnelMode == .shellManaged {
                Text("Shell-managed")
                    .font(.caption).foregroundStyle(.orange)
                    .padding(.horizontal, 12).padding(.bottom, 6)
            }

            Divider()

            // Toggle
            if model.tunnelMode != .shellManaged {
                if model.connectionState == .connected {
                    Button("Disconnect") { Task { await model.disconnect() } }
                        .padding(.horizontal, 4)
                } else if model.isEnrolled {
                    Button("Connect") { Task { await model.connect() } }
                        .padding(.horizontal, 4)
                }
                Divider()
            }

            Button("Open Dashboard") {
                NSApplication.shared.activate(ignoringOtherApps: true)
                // The WindowGroup will show/focus the main window.
                if let window = NSApplication.shared.windows.first(where: { $0.title == "wg0" }) {
                    window.makeKeyAndOrderFront(nil)
                }
            }
            .padding(.horizontal, 4)

            Button("Refresh") { Task { await model.refreshData() } }
                .padding(.horizontal, 4)

            Divider()

            Text("wg0 v\(AppModel.currentVersion)")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 4)

            Button("Quit wg0") { NSApplication.shared.terminate(nil) }
                .padding(.horizontal, 4)
        }
        .padding(.vertical, 4)
    }
}
