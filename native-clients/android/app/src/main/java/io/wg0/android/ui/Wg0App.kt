package io.wg0.android.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import io.wg0.android.network.*
import io.wg0.android.storage.SecureStorage
import kotlinx.coroutines.launch

@Composable
fun Wg0App() {
    MaterialTheme {
        Surface(modifier = Modifier.fillMaxSize()) {
            var signedIn by remember { mutableStateOf(SecureStorage.load(SecureStorage.Key.ACCESS_TOKEN) != null) }
            var email by remember { mutableStateOf("") }
            var password by remember { mutableStateOf("") }
            var status by remember { mutableStateOf(if (signedIn) "Restoring session..." else "Sign in to start.") }
            var isEnrolled by remember { mutableStateOf(SecureStorage.isEnrolled) }
            var profiles by remember { mutableStateOf(emptyList<ProfileInfo>()) }
            var nodes by remember { mutableStateOf(emptyList<NodeInfo>()) }
            var accountInfo by remember { mutableStateOf<AccountMe?>(null) }

            val scope = rememberCoroutineScope()
            val api = remember { LiveBrainApi() }

            // Auto-refresh on resume.
            LaunchedEffect(signedIn) {
                if (signedIn) {
                    val token = SecureStorage.load(SecureStorage.Key.ACCESS_TOKEN) ?: return@LaunchedEffect
                    try {
                        accountInfo = api.getAccountMe(token)
                        val access = api.getMyAccess(token)
                        profiles = access.profiles
                        nodes = access.nodes
                        isEnrolled = SecureStorage.isEnrolled
                        status = if (isEnrolled) "Enrolled. ${profiles.size} profile(s), ${nodes.size} device(s)." else "Not enrolled yet."
                    } catch (e: Exception) {
                        status = "Refresh failed: ${e.message}"
                    }
                }
            }

            if (!signedIn) {
                LoginScreen(
                    email = email, password = password, status = status,
                    onEmailChange = { email = it },
                    onPasswordChange = { password = it },
                    onSignIn = {
                        scope.launch {
                            status = "Signing in..."
                            try {
                                val resp = api.login(LoginRequest(email, password))
                                SecureStorage.save(SecureStorage.Key.ACCESS_TOKEN, resp.access_token)
                                SecureStorage.save(SecureStorage.Key.ACCOUNT_EMAIL, email)
                                signedIn = true
                                status = "Signed in."
                            } catch (e: Exception) {
                                status = "Login failed: ${e.message}"
                            }
                        }
                    },
                )
            } else {
                DashboardScreen(
                    status = status,
                    accountInfo = accountInfo,
                    isEnrolled = isEnrolled,
                    profiles = profiles,
                    nodes = nodes,
                    onSignOut = {
                        SecureStorage.delete(SecureStorage.Key.ACCESS_TOKEN)
                        signedIn = false
                        profiles = emptyList()
                        nodes = emptyList()
                        accountInfo = null
                        isEnrolled = false
                        status = "Signed out."
                    },
                    onRefresh = {
                        scope.launch {
                            val token = SecureStorage.load(SecureStorage.Key.ACCESS_TOKEN) ?: return@launch
                            try {
                                accountInfo = api.getAccountMe(token)
                                val access = api.getMyAccess(token)
                                profiles = access.profiles
                                nodes = access.nodes
                                status = "Refreshed."
                            } catch (e: Exception) {
                                status = "Refresh failed: ${e.message}"
                            }
                        }
                    },
                    onEnroll = { profileId, networkId ->
                        scope.launch {
                            val token = SecureStorage.load(SecureStorage.Key.ACCESS_TOKEN) ?: return@launch
                            status = "Enrolling..."
                            try {
                                val enrollToken = api.requestEnrollToken(token, profileId, networkId)
                                // For MVP: use a placeholder keypair.
                                // Real implementation needs a JNI call to wireguard-tools or
                                // a bundled Curve25519 implementation.
                                val stubPubKey = "placeholder-needs-real-keygen"
                                status = "Enrollment token minted. Real keygen + tunnel integration pending.\n\nInstall command:\n${enrollToken.install_command}"
                            } catch (e: Exception) {
                                status = "Enrollment failed: ${e.message}"
                            }
                        }
                    },
                )
            }
        }
    }
}

@Composable
private fun LoginScreen(
    email: String, password: String, status: String,
    onEmailChange: (String) -> Unit, onPasswordChange: (String) -> Unit,
    onSignIn: () -> Unit,
) {
    Column(
        modifier = Modifier.fillMaxSize().padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text("wg0", style = MaterialTheme.typography.headlineMedium)
        Text("Android connector", style = MaterialTheme.typography.titleMedium)
        Text("Sign in with your wg0 account. Billing and upgrades stay on the web.", style = MaterialTheme.typography.bodyMedium)
        OutlinedTextField(value = email, onValueChange = onEmailChange, label = { Text("Email") }, modifier = Modifier.fillMaxWidth())
        OutlinedTextField(value = password, onValueChange = onPasswordChange, label = { Text("Password") }, modifier = Modifier.fillMaxWidth())
        Button(onClick = onSignIn) { Text("Sign in") }
        Text(status, style = MaterialTheme.typography.bodyMedium)
    }
}

@Composable
private fun DashboardScreen(
    status: String, accountInfo: AccountMe?, isEnrolled: Boolean,
    profiles: List<ProfileInfo>, nodes: List<NodeInfo>,
    onSignOut: () -> Unit, onRefresh: () -> Unit,
    onEnroll: (String, String) -> Unit,
) {
    Column(
        modifier = Modifier.fillMaxSize().padding(24.dp).verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Row(horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth()) {
            Column {
                Text("wg0", style = MaterialTheme.typography.headlineMedium)
                accountInfo?.let {
                    Text(it.user_email, style = MaterialTheme.typography.bodySmall)
                    Text("${it.plan_display_name} · ${it.user_role}", style = MaterialTheme.typography.labelSmall)
                }
            }
            Button(onClick = onSignOut) { Text("Sign out") }
        }

        Text(status, style = MaterialTheme.typography.bodyMedium)

        if (isEnrolled) {
            SecureStorage.load(SecureStorage.Key.OVERLAY_IP)?.let { ip ->
                Card(modifier = Modifier.fillMaxWidth()) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        Text("Enrolled", style = MaterialTheme.typography.labelMedium)
                        Text("Overlay IP: $ip", style = MaterialTheme.typography.titleMedium)
                    }
                }
            }
        }

        if (profiles.isNotEmpty()) {
            Text("Access Profiles", style = MaterialTheme.typography.titleMedium)
            profiles.forEach { p ->
                Card(modifier = Modifier.fillMaxWidth()) {
                    Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(p.name, style = MaterialTheme.typography.titleSmall)
                        p.description?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
                        Text("${p.device_count}${p.device_limit?.let { "/$it" } ?: ""} devices · ${p.allowed_device_kind}", style = MaterialTheme.typography.labelSmall)
                        if (!isEnrolled && p.allowed_network_ids.isNotEmpty()) {
                            Button(onClick = { onEnroll(p.id, p.allowed_network_ids.first()) }) {
                                Text("Enroll in ${p.name}")
                            }
                        }
                    }
                }
            }
        } else if (!isEnrolled) {
            Text("No profiles assigned. Ask your admin.", style = MaterialTheme.typography.bodyMedium)
        }

        if (nodes.isNotEmpty()) {
            Text("Your Devices", style = MaterialTheme.typography.titleMedium)
            nodes.forEach { n ->
                Row(modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                    Column {
                        Text(n.node_name, style = MaterialTheme.typography.bodyMedium)
                        Text("${n.overlay_ip} · ${n.role} · ${n.device_kind}", style = MaterialTheme.typography.labelSmall)
                    }
                    Text(if (n.is_online) "Online" else "Offline",
                        color = if (n.is_online) Color(0xFF22C55E) else Color.Gray,
                        style = MaterialTheme.typography.labelMedium)
                }
            }
        }

        Button(onClick = onRefresh) { Text("Refresh") }
    }
}
