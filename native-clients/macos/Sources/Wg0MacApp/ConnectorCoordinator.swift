import Foundation

// MARK: - Status types

struct LegacyConnectorStatus {
    let installed: Bool      // launchd plist or heartbeat.sh exists
    let tunnelUp: Bool       // socket file exists in /var/run/wireguard/
    let hasNodeId: Bool      // /etc/wireguard/wg0/node_id exists
    /// Which interface name is running: "wg0" or "abs0" (legacy).
    let activeInterface: String?
    /// Which config file exists on disk.
    let configFile: String?

    var description: String {
        if installed && tunnelUp {
            return "Shell connector is running (\(activeInterface ?? "wg0"))."
        }
        if installed { return "Shell connector installed but tunnel is down." }
        if tunnelUp { return "Tunnel is up (\(activeInterface ?? "?")) — no shell connector daemon found." }
        return "No connector found."
    }

    var shellManaged: Bool { installed && tunnelUp }
}

struct TunnelStatus {
    let listenPort: String
    let peers: [PeerStatus]

    var hasRecentHandshake: Bool {
        peers.contains { peer in
            guard let hs = peer.lastHandshake else { return false }
            return Date().timeIntervalSince(hs) < 180
        }
    }

    var isRouteAll: Bool {
        peers.contains { $0.allowedIps.contains("0.0.0.0/0") }
    }

    var summary: String {
        let peerCount = peers.count
        let activeCount = peers.filter { $0.lastHandshake != nil && Date().timeIntervalSince($0.lastHandshake!) < 180 }.count
        let mode = isRouteAll ? "route-all" : "split-tunnel"
        return "\(activeCount)/\(peerCount) peers active · \(mode)"
    }
}

struct PeerStatus {
    let publicKey: String
    let endpoint: String?
    let lastHandshake: Date?
    let rxBytes: Int64
    let txBytes: Int64
    let allowedIps: String

    var isDiscoverPeer: Bool {
        allowedIps.contains("100.64.")
    }
}

// MARK: - Protocol

protocol ConnectorCoordinatorProtocol: Sendable {
    func connect() async throws
    func disconnect() async throws
    func isUp() async -> Bool
}

enum ConnectorError: Error, LocalizedError {
    case notEnrolled
    case shellFailed(cmd: String, exitCode: Int32, stderr: String)
    case configMissing

    var errorDescription: String? {
        switch self {
        case .notEnrolled:
            return "Device is not enrolled. Complete enrollment first."
        case .shellFailed(let cmd, let code, let stderr):
            return "Shell command failed (\(cmd), exit \(code)): \(stderr)"
        case .configMissing:
            return "No WireGuard config found at /etc/wireguard/."
        }
    }
}

// MARK: - Real implementation

actor LiveConnectorCoordinator: ConnectorCoordinatorProtocol {
    static let interfaceName = "wg0"
    static let configDir = "/etc/wireguard"
    static var configPath: String { "\(configDir)/\(interfaceName).conf" }

    static let legacyInterfaceName = "abs0"
    static var legacyConfigPath: String { "\(configDir)/\(legacyInterfaceName).conf" }

    /// All known plist paths the shell connector might have installed.
    static let knownPlists = [
        "/Library/LaunchDaemons/io.wg0.heartbeat.plist",
        "/Library/LaunchDaemons/io.wg0.wireguard.plist",
        "/Library/LaunchDaemons/com.abslink.heartbeat.plist",
        "/Library/LaunchDaemons/com.abslink.wireguard.plist",
    ]

    /// Locate wg / wg-quick in Homebrew (arm64 or x86_64) or /usr/local.
    static var wgQuick: String { findBin("wg-quick") }
    static var wg: String { findBin("wg") }

    private static func findBin(_ name: String) -> String {
        for path in [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
        ] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return "/usr/local/bin/\(name)"
    }

    // ── Detection (NO root, NO password prompt) ────────────────────

    /// Check which WG interface is running by looking at socket files.
    /// /var/run/wireguard/ is world-readable — no root needed.
    nonisolated func detectRunningInterface() -> String? {
        let fm = FileManager.default
        for name in [Self.interfaceName, Self.legacyInterfaceName] {
            if fm.fileExists(atPath: "/var/run/wireguard/\(name).sock") ||
               fm.fileExists(atPath: "/var/run/wireguard/\(name).name") {
                return name
            }
        }
        return nil
    }

    func isUp() async -> Bool {
        detectRunningInterface() != nil
    }

    /// Find which config file exists on disk.
    nonisolated func findConfigPath() -> String? {
        let fm = FileManager.default
        if fm.fileExists(atPath: Self.configPath) { return Self.configPath }
        if fm.fileExists(atPath: Self.legacyConfigPath) { return Self.legacyConfigPath }
        return nil
    }

    /// Detect the shell connector state. No root needed — uses
    /// file existence checks only.
    func detectLegacyConnector() -> LegacyConnectorStatus {
        let fm = FileManager.default
        let keyDir = "/etc/wireguard/wg0"

        let anyPlistExists = Self.knownPlists.contains { fm.fileExists(atPath: $0) }
        let heartbeatExists = fm.fileExists(atPath: "\(keyDir)/heartbeat.sh")
        let nodeIdExists = fm.fileExists(atPath: "\(keyDir)/node_id")
        let activeIface = detectRunningInterface()

        return LegacyConnectorStatus(
            installed: anyPlistExists || heartbeatExists,
            tunnelUp: activeIface != nil,
            hasNodeId: nodeIdExists,
            activeInterface: activeIface,
            configFile: findConfigPath()
        )
    }

    // ── Credential import (NO root — reads files as user) ──────────

    nonisolated func importLegacyCredentials() throws -> (nodeId: String, deviceSecret: String, overlayIp: String?) {
        let keyDir = "/etc/wireguard/wg0"
        let nodeId = try String(contentsOfFile: "\(keyDir)/node_id", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = try String(contentsOfFile: "\(keyDir)/device_secret", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var overlayIp: String? = nil
        for candidate in [Self.configPath, Self.legacyConfigPath] {
            if let config = try? String(contentsOfFile: candidate, encoding: .utf8) {
                for line in config.split(separator: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("Address") {
                        let parts = trimmed.split(separator: "=", maxSplits: 1)
                        if parts.count == 2 {
                            overlayIp = parts[1].trimmingCharacters(in: .whitespaces)
                                .split(separator: "/").first.map(String.init)
                        }
                    }
                }
                break
            }
        }

        return (nodeId, secret, overlayIp)
    }

    // ── Privileged operations (ONE password prompt per action) ──────

    /// Run a shell command with admin privileges via osascript.
    /// macOS shows its standard password dialog once.
    @discardableResult
    private func privileged(_ command: String) async throws -> String {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        return try await shellOutput("/usr/bin/osascript", args: ["-e", script])
    }

    func connect() async throws {
        guard let configFile = findConfigPath() else {
            throw ConnectorError.configMissing
        }
        try await privileged("\(Self.wgQuick) up \(configFile)")
    }

    func disconnect() async throws {
        if let iface = detectRunningInterface() {
            let conf = "\(Self.configDir)/\(iface).conf"
            try await privileged("\(Self.wgQuick) down \(conf)")
        }
    }

    /// Full takeover: stop shell daemons, migrate abs0→wg0 if needed,
    /// bring tunnel up as wg0. Single password prompt.
    func takeoverLegacy() async throws {
        let fm = FileManager.default
        var cmds: [String] = []

        // Stop all known launchd jobs.
        for plist in Self.knownPlists {
            if fm.fileExists(atPath: plist) {
                let label = URL(fileURLWithPath: plist).deletingPathExtension().lastPathComponent
                cmds.append("launchctl bootout system/\(label) 2>/dev/null || true")
                cmds.append("rm -f \(plist)")
            }
        }

        // Remove heartbeat script.
        cmds.append("rm -f /etc/wireguard/wg0/heartbeat.sh")

        // Tear down legacy abs0 if running.
        if detectRunningInterface() == Self.legacyInterfaceName {
            cmds.append("\(Self.wgQuick) down \(Self.legacyConfigPath) 2>/dev/null || true")
            // Rename abs0.conf → wg0.conf.
            if fm.fileExists(atPath: Self.legacyConfigPath) && !fm.fileExists(atPath: Self.configPath) {
                cmds.append("mv \(Self.legacyConfigPath) \(Self.configPath)")
            }
            cmds.append("rm -f /var/run/wireguard/\(Self.legacyInterfaceName).sock /var/run/wireguard/\(Self.legacyInterfaceName).name")
        }

        // Bring up as wg0.
        if fm.fileExists(atPath: Self.configPath) || fm.fileExists(atPath: Self.legacyConfigPath) {
            cmds.append("\(Self.wgQuick) up \(Self.configPath)")
        }

        guard !cmds.isEmpty else { return }
        try await privileged(cmds.joined(separator: " && "))
    }

    /// Full uninstall of the shell connector.
    func uninstallLegacy(keepTunnel: Bool) async throws {
        let fm = FileManager.default
        var cmds: [String] = []

        for plist in Self.knownPlists {
            if fm.fileExists(atPath: plist) {
                let label = URL(fileURLWithPath: plist).deletingPathExtension().lastPathComponent
                cmds.append("launchctl bootout system/\(label) 2>/dev/null || true")
                cmds.append("rm -f \(plist)")
            }
        }
        cmds.append("rm -f /etc/wireguard/wg0/heartbeat.sh")

        if !keepTunnel {
            cmds.append("\(Self.wgQuick) down \(Self.configPath) 2>/dev/null || true")
            cmds.append("\(Self.wgQuick) down \(Self.legacyConfigPath) 2>/dev/null || true")
        }
        cmds.append("rm -f \(Self.legacyConfigPath)")
        cmds.append("rm -f /var/run/wireguard/\(Self.legacyInterfaceName).sock /var/run/wireguard/\(Self.legacyInterfaceName).name")

        guard !cmds.isEmpty else { return }
        try await privileged(cmds.joined(separator: " && "))
    }

    /// Write a WireGuard config to /etc/wireguard/wg0.conf (privileged).
    func writeConfig(_ config: String) async throws {
        // Write via a temp file to avoid shell escaping issues.
        let tmp = NSTemporaryDirectory() + "wg0-conf-\(UUID().uuidString).conf"
        try config.write(toFile: tmp, atomically: true, encoding: .utf8)
        try await privileged("mkdir -p \(Self.configDir) && mv \(tmp) \(Self.configPath) && chmod 600 \(Self.configPath)")
    }

    // ── Shell helpers ──────────────────────────────────────────────

    private func shellOutput(_ cmd: String, args: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cmd)
        process.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw ConnectorError.shellFailed(
                cmd: ([cmd] + args).joined(separator: " "),
                exitCode: process.terminationStatus,
                stderr: stderr.isEmpty ? output : stderr
            )
        }
        return output
    }
}

// MARK: - Mock

struct MockConnectorCoordinator: ConnectorCoordinatorProtocol {
    func connect() async throws { try await Task.sleep(for: .milliseconds(200)) }
    func disconnect() async throws { try await Task.sleep(for: .milliseconds(150)) }
    func isUp() async -> Bool { false }
}
