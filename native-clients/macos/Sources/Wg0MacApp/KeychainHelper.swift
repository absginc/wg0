import Foundation

/// Simple file-based credential storage in ~/Library/Application Support/io.wg0.macos/.
///
/// We avoid the macOS Keychain because unsigned/dev-signed apps get a
/// Keychain password prompt every time the binary changes (every rebuild).
/// The device_secret is already stored in plaintext by the shell connector
/// at /etc/wireguard/wg0/device_secret, so Keychain adds no real security.

enum KeychainHelper {
    private static let appDir: String = {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/io.wg0.macos")
        try? FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true
        )
        return base.path
    }()

    enum Key: String, CaseIterable {
        case accessToken = "access_token"
        case accountEmail = "account_email"
        case deviceSecret = "device_secret"
        case nodeId = "node_id"
        case wgConfig = "wg_config"
        case configVersion = "config_version"
        case overlayIp = "overlay_ip"
        case publicKey = "public_key"
    }

    private static func path(for key: Key) -> String {
        "\(appDir)/\(key.rawValue)"
    }

    // MARK: Write

    static func save(_ key: Key, value: String) {
        let p = path(for: key)
        try? value.write(toFile: p, atomically: true, encoding: .utf8)
        // Restrict permissions: owner-only read/write.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: p
        )
    }

    // MARK: Read

    static func load(_ key: Key) -> String? {
        guard let data = FileManager.default.contents(atPath: path(for: key)),
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: Delete

    static func delete(_ key: Key) {
        try? FileManager.default.removeItem(atPath: path(for: key))
    }

    // MARK: Clear all

    static func clearAll() {
        for key in Key.allCases {
            delete(key)
        }
    }

    // MARK: Convenience

    static var isEnrolled: Bool {
        load(.nodeId) != nil && load(.deviceSecret) != nil
    }
}
