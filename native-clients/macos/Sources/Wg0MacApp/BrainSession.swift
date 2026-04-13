import Foundation

// MARK: - Types

struct AuthSession: Sendable {
    let accessToken: String
    let accountEmail: String
    let userRole: String
}

struct LoginResponse: Codable {
    let access_token: String
    let token_type: String
}

struct LoginRequestBody: Codable {
    let email: String
    let password: String
}

struct MyAccessResponse: Codable {
    let profiles: [ProfileInfo]
    let nodes: [NodeInfo]
}

struct ProfileInfo: Codable, Identifiable {
    let id: String
    let name: String
    let description: String?
    let allowed_network_ids: [String]
    let device_limit: Int?
    let device_count: Int
    let allowed_device_kind: String
    let allowed_roles: [String]
    let allow_rename: Bool
    let allow_delete: Bool
    let allow_route_all: Bool
    let assigned_users: [AssignedUser]
}

struct AssignedUser: Codable {
    let user_id: String
    let email: String
}

struct NodeInfo: Codable, Identifiable {
    let id: String
    let node_name: String
    let overlay_ip: String
    let role: String
    let os_type: String?
    let network_id: String
    let device_profile_id: String?
    let device_kind: String
    let is_online: Bool
    let route_all_traffic: Bool
}

struct EnrollTokenResponse: Codable {
    let token: String
    let network_id: String
    let profile_id: String
    let expires_at: String
    let install_command: String
}

struct EnrollRequest: Codable {
    let token: String
    let public_key: String
    let node_name: String
    let os_type: String?
    let role: String?
    let endpoint: String?
}

struct EnrollResponse: Codable {
    let node_id: String
    let overlay_ip: String
    let network_type: String
    let device_secret: String
    let wg_config: String
}

struct HeartbeatRequest: Codable {
    let endpoint: String?
    let tx_bytes: Int64
    let rx_bytes: Int64
    let route_all_active: Bool
}

struct HeartbeatResponse: Codable {
    let config_version: Int?
    let peers: [PeerInfo]?
}

struct PeerInfo: Codable {
    let public_key: String
    let allowed_ips: String
    let endpoint: String?
    let persistent_keepalive: Int?
}

struct AccountMeResponse: Codable {
    let id: String
    let email: String
    let user_email: String
    let user_role: String
    let plan_code: String
    let plan_display_name: String
}

struct AppVersionInfo: Codable {
    let version: String
    let build: Int
    let url: String
    let notes: String
}

struct LatestVersions: Codable {
    let macos: AppVersionInfo
}

// MARK: - Protocol

protocol BrainSessionProtocol: Sendable {
    func login(email: String, password: String) async throws -> AuthSession
    func getMyAccess(token: String) async throws -> MyAccessResponse
    func getAccountMe(token: String) async throws -> AccountMeResponse
    func requestEnrollToken(token: String, profileId: String, networkId: String) async throws -> EnrollTokenResponse
    func enrollDevice(brainToken: String, enrollToken: String, publicKey: String, nodeName: String, osType: String) async throws -> EnrollResponse
    func heartbeat(token: String, nodeId: String, deviceSecret: String, body: HeartbeatRequest) async throws -> HeartbeatResponse
    func getNodeConfig(token: String, nodeId: String, deviceSecret: String) async throws -> String
    func claimDevice(token: String, nodeId: String, deviceSecret: String) async throws -> [String: Any]
}

// MARK: - Error

enum BrainSessionError: Error, LocalizedError {
    case httpError(statusCode: Int, detail: String)
    case networkError(underlying: Error)
    case decodingError(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .httpError(let code, let detail):
            return "HTTP \(code): \(detail)"
        case .networkError(let err):
            return "Network error: \(err.localizedDescription)"
        case .decodingError(let err):
            return "Decode error: \(err.localizedDescription)"
        }
    }
}

// MARK: - Real implementation

actor LiveBrainSession: BrainSessionProtocol {
    let baseURL: String
    private let session = URLSession.shared

    init(baseURL: String = "https://connect.wg0.io") {
        self.baseURL = baseURL
    }

    // MARK: Login

    func login(email: String, password: String) async throws -> AuthSession {
        let body = LoginRequestBody(email: email, password: password)
        let resp: LoginResponse = try await post("/api/v1/auth/login", body: body, token: nil)

        // Decode the JWT to extract user_role (the `role` claim).
        // Fallback to "member" if decoding fails.
        let role = decodeJwtRole(resp.access_token) ?? "member"

        return AuthSession(
            accessToken: resp.access_token,
            accountEmail: email,
            userRole: role
        )
    }

    // MARK: My Access

    func getMyAccess(token: String) async throws -> MyAccessResponse {
        return try await get("/api/v1/my-access", token: token)
    }

    func getAccountMe(token: String) async throws -> AccountMeResponse {
        return try await get("/api/v1/accounts/me", token: token)
    }

    // MARK: Enrollment

    func requestEnrollToken(token: String, profileId: String, networkId: String) async throws -> EnrollTokenResponse {
        struct Body: Codable { let network_id: String }
        return try await post("/api/v1/my-access/\(profileId)/enroll-token",
                              body: Body(network_id: networkId), token: token)
    }

    func enrollDevice(brainToken: String, enrollToken: String, publicKey: String, nodeName: String, osType: String) async throws -> EnrollResponse {
        let body = EnrollRequest(
            token: enrollToken,
            public_key: publicKey,
            node_name: nodeName,
            os_type: osType,
            role: "client",
            endpoint: nil
        )
        return try await post("/api/v1/enroll/register", body: body, token: nil)
    }

    // MARK: Heartbeat

    func heartbeat(token: String, nodeId: String, deviceSecret: String, body: HeartbeatRequest) async throws -> HeartbeatResponse {
        var req = try buildRequest("POST", path: "/api/v1/nodes/\(nodeId)/heartbeat")
        req.addValue(deviceSecret, forHTTPHeaderField: "X-Device-Secret")
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: req)
        try checkHTTPResponse(response, data: data)
        return try JSONDecoder().decode(HeartbeatResponse.self, from: data)
    }

    // MARK: Claim device

    func claimDevice(token: String, nodeId: String, deviceSecret: String) async throws -> [String: Any] {
        var req = try buildRequest("POST", path: "/api/v1/nodes/\(nodeId)/claim")
        req.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.addValue(deviceSecret, forHTTPHeaderField: "X-Device-Secret")

        let (data, response) = try await session.data(for: req)
        try checkHTTPResponse(response, data: data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BrainSessionError.decodingError(underlying: NSError(domain: "BrainSession", code: 0))
        }
        return json
    }

    // MARK: Config fetch

    func getNodeConfig(token: String, nodeId: String, deviceSecret: String) async throws -> String {
        var req = try buildRequest("GET", path: "/api/v1/nodes/\(nodeId)/config")
        req.addValue(deviceSecret, forHTTPHeaderField: "X-Device-Secret")

        let (data, response) = try await session.data(for: req)
        try checkHTTPResponse(response, data: data)

        // The config endpoint returns a JSON object with a wg_config field.
        struct ConfigResp: Codable { let wg_config: String }
        let decoded = try JSONDecoder().decode(ConfigResp.self, from: data)
        return decoded.wg_config
    }

    // MARK: Version check

    func checkForUpdate() async -> AppVersionInfo? {
        guard let url = URL(string: "https://wg0.io/downloads/latest-version.json") else { return nil }
        do {
            let (data, _) = try await session.data(from: url)
            let versions = try JSONDecoder().decode(LatestVersions.self, from: data)
            return versions.macos
        } catch {
            return nil
        }
    }

    // MARK: Private helpers

    private func get<T: Decodable>(_ path: String, token: String?) async throws -> T {
        var req = try buildRequest("GET", path: path)
        if let t = token {
            req.addValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: req)
        try checkHTTPResponse(response, data: data)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw BrainSessionError.decodingError(underlying: error)
        }
    }

    private func post<B: Encodable, T: Decodable>(_ path: String, body: B, token: String?) async throws -> T {
        var req = try buildRequest("POST", path: path)
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        if let t = token {
            req.addValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: req)
        try checkHTTPResponse(response, data: data)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw BrainSessionError.decodingError(underlying: error)
        }
    }

    private func buildRequest(_ method: String, path: String) throws -> URLRequest {
        guard let url = URL(string: baseURL + path) else {
            throw BrainSessionError.httpError(statusCode: 0, detail: "Invalid URL: \(baseURL + path)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 30
        return req
    }

    private func checkHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            // Try to extract the detail field from the error body.
            struct ErrorBody: Codable { let detail: String }
            let detail: String
            if let err = try? JSONDecoder().decode(ErrorBody.self, from: data) {
                detail = err.detail
            } else {
                detail = String(data: data, encoding: .utf8) ?? "Unknown error"
            }
            throw BrainSessionError.httpError(statusCode: http.statusCode, detail: detail)
        }
    }

    private func decodeJwtRole(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
        // Pad to multiple of 4 for base64.
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) else { return nil }
        struct Claims: Codable { let role: String? }
        return try? JSONDecoder().decode(Claims.self, from: data).role
    }
}

// MARK: - Mock (for previews / testing)

struct MockBrainSession: BrainSessionProtocol {
    func login(email: String, password: String) async throws -> AuthSession {
        try await Task.sleep(for: .milliseconds(250))
        return AuthSession(accessToken: "mock-token", accountEmail: email, userRole: "owner")
    }
    func getMyAccess(token: String) async throws -> MyAccessResponse {
        MyAccessResponse(profiles: [], nodes: [])
    }
    func getAccountMe(token: String) async throws -> AccountMeResponse {
        AccountMeResponse(id: "mock", email: "mock@example.com", user_email: "mock@example.com", user_role: "owner", plan_code: "free", plan_display_name: "Free")
    }
    func requestEnrollToken(token: String, profileId: String, networkId: String) async throws -> EnrollTokenResponse {
        EnrollTokenResponse(token: "mock-enroll", network_id: networkId, profile_id: profileId, expires_at: "2099-01-01", install_command: "echo mock")
    }
    func enrollDevice(brainToken: String, enrollToken: String, publicKey: String, nodeName: String, osType: String) async throws -> EnrollResponse {
        EnrollResponse(node_id: "mock", overlay_ip: "10.0.0.1", network_type: "overlay", device_secret: "mock-secret", wg_config: "[Interface]\nPrivateKey=mock\n")
    }
    func heartbeat(token: String, nodeId: String, deviceSecret: String, body: HeartbeatRequest) async throws -> HeartbeatResponse {
        HeartbeatResponse(config_version: 1, peers: nil)
    }
    func getNodeConfig(token: String, nodeId: String, deviceSecret: String) async throws -> String {
        "[Interface]\nPrivateKey=mock\n"
    }
    func claimDevice(token: String, nodeId: String, deviceSecret: String) async throws -> [String: Any] {
        ["status": "claimed", "node_id": nodeId]
    }
}
