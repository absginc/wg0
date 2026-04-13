import Foundation
import CryptoKit

@MainActor
final class AppModel: ObservableObject {
    enum Screen { case login, dashboard }
    enum ConnectionState: String { case disconnected, connecting, connected, degraded }
    enum TunnelMode: String { case none, shellManaged, appManaged }

    @Published var screen: Screen = .login
    @Published var email = ""
    @Published var password = ""
    @Published var statusMessage = "Sign in to begin."
    @Published var connectionState: ConnectionState = .disconnected
    @Published var tunnelMode: TunnelMode = .none
    @Published var lastHeartbeatDescription = "No heartbeat yet"
    @Published var deviceName = Host.current().localizedName ?? "This Mac"

    @Published var legacyStatus: LegacyConnectorStatus?
    @Published var profiles: [ProfileInfo] = []
    @Published var nodes: [NodeInfo] = []
    @Published var accountInfo: AccountMeResponse?

    @Published var isEnrolled: Bool = false
    @Published var enrolledNodeId: String?
    @Published var enrolledOverlayIp: String?

    @Published var availableUpdate: AppVersionInfo?
    static let currentVersion = "0.2.0"
    static let currentBuild = 2

    let brainSession: BrainSessionProtocol
    let connectorCoordinator: any ConnectorCoordinatorProtocol

    private var heartbeatTask: Task<Void, Never>?
    private var accessToken: String?

    init(
        brainSession: BrainSessionProtocol = LiveBrainSession(),
        connectorCoordinator: any ConnectorCoordinatorProtocol = LiveConnectorCoordinator()
    ) {
        self.brainSession = brainSession
        self.connectorCoordinator = connectorCoordinator
        if let token = KeychainHelper.load(.accessToken),
           let nodeId = KeychainHelper.load(.nodeId) {
            self.accessToken = token
            self.enrolledNodeId = nodeId
            self.enrolledOverlayIp = KeychainHelper.load(.overlayIp)
            self.isEnrolled = true
            self.screen = .dashboard
            self.statusMessage = "Restoring session..."
            Task { await refreshData() }
        }
    }

    // MARK: - Sign in

    func signIn() async {
        statusMessage = "Signing in..."
        do {
            // Clear stale saved state so refreshData reads from disk.
            KeychainHelper.clearAll()
            isEnrolled = false
            enrolledNodeId = nil
            enrolledOverlayIp = nil

            let session = try await brainSession.login(email: email, password: password)
            accessToken = session.accessToken
            KeychainHelper.save(.accessToken, value: session.accessToken)
            KeychainHelper.save(.accountEmail, value: session.accountEmail)
            screen = .dashboard
            await refreshData()
        } catch {
            statusMessage = "Sign-in failed: \(error.localizedDescription)"
        }
    }

    func signOut() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        accessToken = nil
        profiles = []
        nodes = []
        accountInfo = nil
        isEnrolled = false
        enrolledNodeId = nil
        enrolledOverlayIp = nil
        tunnelMode = .none
        KeychainHelper.delete(.accessToken)
        screen = .login
        statusMessage = "Signed out."
    }

    // MARK: - Data refresh (no root, no password prompt)

    func refreshData() async {
        guard let token = accessToken else { return }
        do {
            let me = try await brainSession.getAccountMe(token: token)
            accountInfo = me
            let access = try await brainSession.getMyAccess(token: token)
            profiles = access.profiles
            nodes = access.nodes

            // Detect connector state (file checks only — no root).
            if let liveCoord = connectorCoordinator as? LiveConnectorCoordinator {
                let ls = await liveCoord.detectLegacyConnector()
                legacyStatus = ls

                // If a shell connector is on disk, its credentials are
                // the source of truth — overwrite any stale saved data.
                if ls.hasNodeId {
                    if let creds = try? liveCoord.importLegacyCredentials() {
                        KeychainHelper.save(.nodeId, value: creds.nodeId)
                        KeychainHelper.save(.deviceSecret, value: creds.deviceSecret)
                        if let ip = creds.overlayIp {
                            KeychainHelper.save(.overlayIp, value: ip)
                            enrolledOverlayIp = ip
                        }
                        enrolledNodeId = creds.nodeId
                        isEnrolled = true
                    }
                }

                // Fall back to saved state if no shell connector.
                if !isEnrolled, let nodeId = KeychainHelper.load(.nodeId) {
                    enrolledNodeId = nodeId
                    enrolledOverlayIp = KeychainHelper.load(.overlayIp)
                    isEnrolled = true
                }

                if ls.tunnelUp {
                    connectionState = .connected
                    tunnelMode = ls.shellManaged ? .shellManaged : .appManaged
                } else if tunnelMode == .shellManaged {
                    connectionState = .disconnected
                    tunnelMode = .none
                }

                // Auto-claim: on-disk node_id but brain doesn't know
                // this user owns the device yet.
                if isEnrolled, ls.hasNodeId {
                    await autoClaimIfNeeded()
                }
            } else {
                // No live coordinator — restore from saved state.
                if let nodeId = KeychainHelper.load(.nodeId) {
                    enrolledNodeId = nodeId
                    enrolledOverlayIp = KeychainHelper.load(.overlayIp)
                    isEnrolled = true
                }
            }

            // Check for app updates.
            if let liveBrain = brainSession as? LiveBrainSession,
               let latest = await liveBrain.checkForUpdate(),
               latest.build > Self.currentBuild {
                availableUpdate = latest
            }

            if statusMessage.starts(with: "Restoring") || statusMessage.starts(with: "Not enrolled") || statusMessage.starts(with: "Sign in") {
                if tunnelMode == .shellManaged {
                    statusMessage = "Connected via shell connector. Use Take Over to switch to native app."
                } else if isEnrolled {
                    statusMessage = "Enrolled as \(enrolledOverlayIp ?? "unknown"). \(profiles.count) profile(s), \(nodes.count) device(s)."
                } else {
                    statusMessage = "Not enrolled yet. Pick a profile to get started."
                }
            }
        } catch {
            statusMessage = "Data refresh failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Auto-claim

    /// Claim the on-disk device if it's not already in the user's
    /// node list. Idempotent — skips if the node_id is already
    /// present in the API response.
    private func autoClaimIfNeeded() async {
        guard let nodeId = enrolledNodeId,
              let secret = KeychainHelper.load(.deviceSecret),
              let token = accessToken else { return }

        // Skip if this device already appears in our node list.
        if nodes.contains(where: { $0.id == nodeId }) { return }

        do {
            let result = try await brainSession.claimDevice(
                token: token, nodeId: nodeId, deviceSecret: secret
            )
            let status = result["status"] as? String ?? "claimed"
            if status != "already_claimed" {
                statusMessage = "Device claimed and linked to your account."
            }

            // Re-fetch nodes after claiming.
            let access = try await brainSession.getMyAccess(token: token)
            profiles = access.profiles
            nodes = access.nodes
        } catch {
            // Non-fatal — device might already be claimed by another user.
        }
    }

    // MARK: - Legacy takeover (one password prompt)

    func takeoverLegacy() async {
        guard let liveCoord = connectorCoordinator as? LiveConnectorCoordinator else { return }
        statusMessage = "Taking over (admin password required)..."
        do {
            // Import credentials first (no root needed).
            let creds = try liveCoord.importLegacyCredentials()
            KeychainHelper.save(.nodeId, value: creds.nodeId)
            KeychainHelper.save(.deviceSecret, value: creds.deviceSecret)
            if let ip = creds.overlayIp {
                KeychainHelper.save(.overlayIp, value: ip)
                enrolledOverlayIp = ip
            }
            enrolledNodeId = creds.nodeId
            isEnrolled = true

            // Single privileged operation: stop daemons, migrate, bring up.
            try await liveCoord.takeoverLegacy()

            tunnelMode = .appManaged
            connectionState = .connected
            startHeartbeat()

            legacyStatus = await liveCoord.detectLegacyConnector()
            statusMessage = "Takeover complete. Tunnel running as wg0, native heartbeat active."
        } catch {
            statusMessage = "Takeover failed: \(error.localizedDescription)"
        }
    }

    func uninstallLegacy(keepTunnel: Bool) async {
        guard let liveCoord = connectorCoordinator as? LiveConnectorCoordinator else { return }
        statusMessage = "Removing shell connector (admin password required)..."
        do {
            try await liveCoord.uninstallLegacy(keepTunnel: keepTunnel)
            legacyStatus = await liveCoord.detectLegacyConnector()
            if !keepTunnel {
                connectionState = .disconnected
                tunnelMode = .none
            }
            statusMessage = keepTunnel
                ? "Shell connector removed. Tunnel still up."
                : "Shell connector removed and tunnel stopped."
        } catch {
            statusMessage = "Uninstall failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Enrollment

    func enroll(profileId: String, networkId: String) async {
        guard let token = accessToken else { return }
        statusMessage = "Enrolling..."
        do {
            let enrollToken = try await brainSession.requestEnrollToken(
                token: token, profileId: profileId, networkId: networkId
            )
            let privateKey = Curve25519.KeyAgreement.PrivateKey()
            let publicKeyB64 = privateKey.publicKey.rawRepresentation.base64EncodedString()
            let privateKeyB64 = privateKey.rawRepresentation.base64EncodedString()

            let response = try await brainSession.enrollDevice(
                brainToken: token, enrollToken: enrollToken.token,
                publicKey: publicKeyB64, nodeName: deviceName, osType: "macos"
            )

            KeychainHelper.save(.nodeId, value: response.node_id)
            KeychainHelper.save(.deviceSecret, value: response.device_secret)
            KeychainHelper.save(.overlayIp, value: response.overlay_ip)
            KeychainHelper.save(.wgConfig, value: response.wg_config)
            KeychainHelper.save(.publicKey, value: publicKeyB64)

            let config = response.wg_config.replacingOccurrences(
                of: "# PrivateKey = <CONNECTOR_FILLS_THIS_IN>",
                with: "PrivateKey = \(privateKeyB64)"
            )

            if let liveCoord = connectorCoordinator as? LiveConnectorCoordinator {
                try await liveCoord.writeConfig(config)
            }

            enrolledNodeId = response.node_id
            enrolledOverlayIp = response.overlay_ip
            isEnrolled = true
            statusMessage = "Enrolled! Overlay IP: \(response.overlay_ip). Ready to connect."
            await refreshData()
        } catch {
            statusMessage = "Enrollment failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Tunnel control

    func connect() async {
        guard isEnrolled else {
            statusMessage = "Not enrolled — pick a profile first."
            return
        }
        connectionState = .connecting
        statusMessage = "Starting tunnel (admin password required)..."
        do {
            try await connectorCoordinator.connect()
            connectionState = .connected
            tunnelMode = .appManaged
            statusMessage = "Tunnel connected."
            startHeartbeat()
        } catch {
            connectionState = .degraded
            statusMessage = "Connect failed: \(error.localizedDescription)"
        }
    }

    func disconnect() async {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        statusMessage = "Stopping tunnel..."
        do {
            try await connectorCoordinator.disconnect()
            connectionState = .disconnected
            tunnelMode = .none
            statusMessage = "Tunnel disconnected."
            lastHeartbeatDescription = "Heartbeat stopped"
        } catch {
            connectionState = .degraded
            statusMessage = "Disconnect failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Heartbeat (app-managed only, no wg show, no root)

    func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sendHeartbeat()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func sendHeartbeat() async {
        guard let nodeId = enrolledNodeId,
              let secret = KeychainHelper.load(.deviceSecret),
              let token = accessToken else { return }

        // In app-managed mode, read real tunnel stats. This calls
        // privileged wg show — macOS caches the admin auth for a few
        // minutes so it won't prompt on every tick after the first.
        // In shell-managed mode, send zeros — the shell connector's
        // own heartbeat reports the real stats.
        var endpoint: String? = nil
        var txBytes: Int64 = 0
        var rxBytes: Int64 = 0
        var routeAllActive = false

        if tunnelMode == .appManaged,
           let liveCoord = connectorCoordinator as? LiveConnectorCoordinator,
           let stats = await liveCoord.readTunnelStats() {
            endpoint = stats.endpoint
            txBytes = stats.txBytes
            rxBytes = stats.rxBytes
            routeAllActive = stats.routeAllActive
        }

        let body = HeartbeatRequest(
            endpoint: endpoint, tx_bytes: txBytes, rx_bytes: rxBytes,
            route_all_active: routeAllActive
        )

        do {
            let resp = try await brainSession.heartbeat(
                token: token, nodeId: nodeId, deviceSecret: secret, body: body
            )
            let formatter = DateFormatter()
            formatter.timeStyle = .medium
            lastHeartbeatDescription = "Last: \(formatter.string(from: Date()))"

            // Re-check tunnel is still up (file check, no root).
            if let liveCoord = connectorCoordinator as? LiveConnectorCoordinator {
                let iface = liveCoord.detectRunningInterface()
                if iface != nil {
                    connectionState = .connected
                } else {
                    connectionState = .degraded
                    lastHeartbeatDescription = "Tunnel down"
                }
            }

            if let newVersion = resp.config_version,
               let storedStr = KeychainHelper.load(.configVersion),
               let stored = Int(storedStr), newVersion > stored {
                await refreshConfig()
            }
            if let v = resp.config_version {
                KeychainHelper.save(.configVersion, value: String(v))
            }
        } catch {
            lastHeartbeatDescription = "Heartbeat failed: \(error.localizedDescription)"
        }
    }

    private func refreshConfig() async {
        guard let nodeId = enrolledNodeId,
              let secret = KeychainHelper.load(.deviceSecret),
              let token = accessToken else { return }
        do {
            let rawConfig = try await brainSession.getNodeConfig(
                token: token, nodeId: nodeId, deviceSecret: secret
            )

            // The brain returns wg_config with a placeholder PrivateKey.
            // Reinsert the locally stored key before writing to disk.
            let privateKey = KeychainHelper.load(.publicKey).flatMap { _ in
                // The actual private key is stored on disk by the
                // enrollment flow or the shell connector.
                try? String(contentsOfFile: "/etc/wireguard/wg0/private.key", encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            let config: String
            if let pk = privateKey {
                config = rawConfig.replacingOccurrences(
                    of: "# PrivateKey = <CONNECTOR_FILLS_THIS_IN>",
                    with: "PrivateKey = \(pk)"
                )
            } else {
                config = rawConfig
            }

            KeychainHelper.save(.wgConfig, value: config)

            // Write to disk AND apply live via wg syncconf (no restart).
            if let liveCoord = connectorCoordinator as? LiveConnectorCoordinator {
                try await liveCoord.writeAndSyncConfig(config)
            }
            statusMessage = "Config refreshed and applied."
        } catch {
            statusMessage = "Config refresh failed: \(error.localizedDescription)"
        }
    }
}
