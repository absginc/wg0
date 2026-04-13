package io.wg0.android.network

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL

// ── Data types ──────────────────────────────────────────────────────────────

@Serializable data class LoginRequest(val email: String, val password: String)
@Serializable data class LoginResponse(val access_token: String, val token_type: String)

@Serializable data class AccountMe(
    val id: String, val email: String, val user_email: String,
    val user_role: String, val plan_code: String, val plan_display_name: String,
)

@Serializable data class MyAccessResponse(
    val profiles: List<ProfileInfo>, val nodes: List<NodeInfo>,
)

@Serializable data class ProfileInfo(
    val id: String, val name: String, val description: String? = null,
    val allowed_network_ids: List<String>,
    val device_limit: Int? = null, val device_count: Int,
    val allowed_device_kind: String, val allowed_roles: List<String>,
    val allow_rename: Boolean, val allow_delete: Boolean, val allow_route_all: Boolean,
    val assigned_users: List<AssignedUser> = emptyList(),
)

@Serializable data class AssignedUser(val user_id: String, val email: String)

@Serializable data class NodeInfo(
    val id: String, val node_name: String, val overlay_ip: String,
    val role: String, val os_type: String? = null,
    val network_id: String, val device_profile_id: String? = null,
    val device_kind: String, val is_online: Boolean, val route_all_traffic: Boolean,
)

@Serializable data class EnrollTokenResponse(
    val token: String, val network_id: String, val profile_id: String,
    val expires_at: String, val install_command: String,
)

@Serializable data class EnrollRequest(
    val token: String, val public_key: String, val node_name: String,
    val os_type: String? = null, val role: String? = null, val endpoint: String? = null,
)

@Serializable data class EnrollResponse(
    val node_id: String, val overlay_ip: String, val network_type: String,
    val device_secret: String, val wg_config: String,
)

@Serializable data class HeartbeatRequest(
    val endpoint: String? = null, val tx_bytes: Long = 0, val rx_bytes: Long = 0,
    val route_all_active: Boolean = false,
)

@Serializable data class HeartbeatResponse(
    val config_version: Int? = null,
)

// ── Interface ───────────────────────────────────────────────────────────────

interface BrainApi {
    suspend fun login(request: LoginRequest): LoginResponse
    suspend fun getAccountMe(token: String): AccountMe
    suspend fun getMyAccess(token: String): MyAccessResponse
    suspend fun requestEnrollToken(token: String, profileId: String, networkId: String): EnrollTokenResponse
    suspend fun enrollDevice(enrollToken: String, publicKey: String, nodeName: String, osType: String): EnrollResponse
    suspend fun heartbeat(nodeId: String, deviceSecret: String, body: HeartbeatRequest): HeartbeatResponse
}

// ── Real implementation (HttpURLConnection — no OkHttp dep for MVP) ─────────

class LiveBrainApi(private val baseUrl: String = "https://connect.wg0.io") : BrainApi {
    private val json = Json { ignoreUnknownKeys = true }

    override suspend fun login(request: LoginRequest): LoginResponse {
        return post("/api/v1/auth/login", json.encodeToString(LoginRequest.serializer(), request), null)
    }

    override suspend fun getAccountMe(token: String): AccountMe {
        return get("/api/v1/accounts/me", token)
    }

    override suspend fun getMyAccess(token: String): MyAccessResponse {
        return get("/api/v1/my-access", token)
    }

    override suspend fun requestEnrollToken(token: String, profileId: String, networkId: String): EnrollTokenResponse {
        @Serializable data class Body(val network_id: String)
        return post("/api/v1/my-access/$profileId/enroll-token",
            json.encodeToString(Body.serializer(), Body(networkId)), token)
    }

    override suspend fun enrollDevice(enrollToken: String, publicKey: String, nodeName: String, osType: String): EnrollResponse {
        val req = EnrollRequest(token = enrollToken, public_key = publicKey, node_name = nodeName, os_type = osType, role = "client")
        return post("/api/v1/enroll/register", json.encodeToString(EnrollRequest.serializer(), req), null)
    }

    override suspend fun heartbeat(nodeId: String, deviceSecret: String, body: HeartbeatRequest): HeartbeatResponse {
        val conn = openConnection("POST", "/api/v1/nodes/$nodeId/heartbeat")
        conn.setRequestProperty("X-Device-Secret", deviceSecret)
        conn.setRequestProperty("Content-Type", "application/json")
        writeBody(conn, json.encodeToString(HeartbeatRequest.serializer(), body))
        val respBody = readResponse(conn)
        checkStatus(conn, respBody)
        return json.decodeFromString(HeartbeatResponse.serializer(), respBody)
    }

    // ── Private helpers ─────────────────────────────────────────────────────

    private inline fun <reified T> get(path: String, token: String?): T {
        val conn = openConnection("GET", path)
        token?.let { conn.setRequestProperty("Authorization", "Bearer $it") }
        val body = readResponse(conn)
        checkStatus(conn, body)
        return json.decodeFromString(body)
    }

    private inline fun <reified T> post(path: String, jsonBody: String, token: String?): T {
        val conn = openConnection("POST", path)
        conn.setRequestProperty("Content-Type", "application/json")
        token?.let { conn.setRequestProperty("Authorization", "Bearer $it") }
        writeBody(conn, jsonBody)
        val body = readResponse(conn)
        checkStatus(conn, body)
        return json.decodeFromString(body)
    }

    private fun openConnection(method: String, path: String): HttpURLConnection {
        val url = URL("$baseUrl$path")
        val conn = url.openConnection() as HttpURLConnection
        conn.requestMethod = method
        conn.connectTimeout = 30_000
        conn.readTimeout = 30_000
        return conn
    }

    private fun writeBody(conn: HttpURLConnection, body: String) {
        conn.doOutput = true
        OutputStreamWriter(conn.outputStream, Charsets.UTF_8).use { it.write(body) }
    }

    private fun readResponse(conn: HttpURLConnection): String {
        val stream = if (conn.responseCode in 200..299) conn.inputStream else conn.errorStream
        return stream?.bufferedReader()?.readText() ?: ""
    }

    private fun checkStatus(conn: HttpURLConnection, body: String) {
        if (conn.responseCode !in 200..299) {
            val detail = try {
                @Serializable data class Err(val detail: String)
                json.decodeFromString(Err.serializer(), body).detail
            } catch (_: Exception) { body }
            throw BrainApiException(conn.responseCode, detail)
        }
    }
}

class BrainApiException(val statusCode: Int, val detail: String) :
    Exception("HTTP $statusCode: $detail")
