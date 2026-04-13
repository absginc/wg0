import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            switch model.screen {
            case .login:  LoginView()
            case .dashboard: DashboardView()
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 500)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.96, green: 0.98, blue: 1.0),
                    Color(red: 0.90, green: 0.94, blue: 0.99)
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
    }
}

// MARK: - Login

private struct LoginView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("wg0")
                .font(.system(size: 30, weight: .bold))
            Text("macOS connector")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Sign in with your wg0 account.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                TextField("Email", text: $model.email)
                    .textFieldStyle(.roundedBorder)
                SecureField("Password", text: $model.password)
                    .textFieldStyle(.roundedBorder)
                Button("Sign in") {
                    Task { await model.signIn() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .frame(maxWidth: 320)

            Text(model.statusMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer()

            Text("wg0 v\(AppModel.currentVersion) (build \(AppModel.currentBuild))")
                .font(.caption)
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Dashboard

private struct DashboardView: View {
    @EnvironmentObject private var model: AppModel

    /// True if the shell connector or app already has this device running.
    private var deviceExists: Bool {
        model.isEnrolled || model.legacyStatus?.hasNodeId == true
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    VStack(alignment: .leading) {
                        Text("wg0").font(.system(size: 28, weight: .bold))
                        if let me = model.accountInfo {
                            Text(me.user_email).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Button("Sign out") { model.signOut() }
                            .buttonStyle(.bordered).controlSize(.small)
                        Text("v\(AppModel.currentVersion)")
                            .font(.caption).foregroundColor(.gray)
                    }
                }

                // Update banner
                if let update = model.availableUpdate {
                    UpdateBanner(update: update)
                }

                // Status cards
                HStack(spacing: 12) {
                    StatusCard(title: "Device", value: model.deviceName)
                    StatusCard(
                        title: "Tunnel",
                        value: tunnelLabel,
                        color: model.connectionState == .connected ? .green : .gray
                    )
                    StatusCard(title: "Heartbeat", value: model.lastHeartbeatDescription)
                }

                Text(model.statusMessage)
                    .font(.callout).foregroundStyle(.secondary)

                // ── Shell connector section ──
                if let ls = model.legacyStatus, ls.installed || ls.tunnelUp {
                    ShellConnectorSection(legacy: ls)
                }

                // ── Tunnel controls (app-managed mode only) ──
                if model.tunnelMode != .shellManaged && deviceExists {
                    TunnelControls()
                }

                if let ip = model.enrolledOverlayIp {
                    HStack {
                        Text("Overlay IP:").font(.caption).foregroundStyle(.secondary)
                        Text(ip).font(.caption.monospaced())
                    }
                }

                Divider()

                // ── Profiles (only show enroll if no device exists) ──
                if !model.profiles.isEmpty {
                    Text("Access Profiles").font(.headline)
                    ForEach(model.profiles) { profile in
                        ProfileCard(profile: profile, showEnroll: !deviceExists)
                    }
                } else if !deviceExists {
                    Text("No access profiles assigned.").foregroundStyle(.secondary)
                    Text("Ask your org admin to assign you a profile.")
                        .font(.footnote).foregroundStyle(.tertiary)
                }

                // ── Devices ──
                if !model.nodes.isEmpty {
                    Text("Your Devices").font(.headline).padding(.top, 8)
                    ForEach(model.nodes) { node in
                        DeviceRow(node: node)
                    }
                }

                Button("Refresh") { Task { await model.refreshData() } }
                    .buttonStyle(.bordered).controlSize(.small).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var tunnelLabel: String {
        switch model.tunnelMode {
        case .shellManaged: return "Shell-managed"
        case .appManaged:   return model.connectionState.rawValue.capitalized
        case .none:         return model.connectionState.rawValue.capitalized
        }
    }
}

// MARK: - Update banner

private struct UpdateBanner: View {
    let update: AppVersionInfo
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("wg0 v\(update.version) available")
                    .font(.subheadline.weight(.semibold))
                Text(update.notes).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Link("Download", destination: URL(string: update.url)!)
                .buttonStyle(.borderedProminent).controlSize(.small)
        }
        .padding(12)
        .background(.blue.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Shell connector section

private struct ShellConnectorSection: View {
    @EnvironmentObject private var model: AppModel
    let legacy: LegacyConnectorStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: legacy.tunnelUp ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(legacy.tunnelUp ? .green : .orange)
                Text("Shell Connector").font(.subheadline.weight(.semibold))
                if let iface = legacy.activeInterface {
                    Badge(iface, color: .blue)
                }
            }

            Text(legacy.description).font(.caption).foregroundStyle(.secondary)

            if legacy.shellManaged {
                Text("The shell daemon is managing your tunnel and heartbeat. Take over to let this app manage it, or remove the shell connector entirely.")
                    .font(.caption).foregroundStyle(.tertiary)
            }

            HStack(spacing: 10) {
                Button("Take over") {
                    Task { await model.takeoverLegacy() }
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .help("Stop shell daemons, migrate to wg0, start native heartbeat. One admin prompt.")

                Button("Remove shell connector") {
                    Task { await model.uninstallLegacy(keepTunnel: false) }
                }
                .buttonStyle(.bordered).controlSize(.small)
                .help("Remove all shell connector daemons and scripts.")
            }
        }
        .padding(12)
        .background(legacy.tunnelUp ? .green.opacity(0.06) : .orange.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Tunnel controls (app-managed)

private struct TunnelControls: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Button("Connect") { Task { await model.connect() } }
                .buttonStyle(.borderedProminent)
                .disabled(model.connectionState == .connected || model.connectionState == .connecting)
            Button("Disconnect") { Task { await model.disconnect() } }
                .buttonStyle(.bordered)
                .disabled(model.connectionState == .disconnected)
        }
    }
}

// MARK: - Profile card

private struct ProfileCard: View {
    @EnvironmentObject private var model: AppModel
    let profile: ProfileInfo
    let showEnroll: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(profile.name).font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(profile.device_count)\(profile.device_limit.map { "/\($0)" } ?? "") devices")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let desc = profile.description {
                Text(desc).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Badge(profile.allowed_device_kind, color: .blue)
                if profile.allowed_roles.contains("host") { Badge("Host", color: .purple) }
            }
            if showEnroll, let firstNet = profile.allowed_network_ids.first {
                Button("Enroll this Mac in \(profile.name)") {
                    Task { await model.enroll(profileId: profile.id, networkId: firstNet) }
                }
                .buttonStyle(.borderedProminent).controlSize(.small).padding(.top, 4)
            }
        }
        .padding(14)
        .background(.white.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Device row

private struct DeviceRow: View {
    let node: NodeInfo
    var body: some View {
        HStack {
            Circle()
                .fill(node.is_online ? Color.green : Color.gray.opacity(0.4))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading) {
                Text(node.node_name).font(.subheadline.weight(.medium))
                Text("\(node.overlay_ip) · \(node.role) · \(node.device_kind)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(node.is_online ? "Online" : "Offline")
                .font(.caption.weight(.semibold))
                .foregroundStyle(node.is_online ? .green : .secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Reusable

private struct StatusCard: View {
    let title: String; let value: String; var color: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.headline).foregroundStyle(color)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct Badge: View {
    let text: String; let color: Color
    init(_ text: String, color: Color) { self.text = text; self.color = color }
    var body: some View {
        Text(text).font(.system(size: 10, weight: .bold)).textCase(.uppercase)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.12)).foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
