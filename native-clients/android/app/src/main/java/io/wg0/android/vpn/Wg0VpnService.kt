package io.wg0.android.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import io.wg0.android.network.HeartbeatRequest
import io.wg0.android.network.LiveBrainApi
import io.wg0.android.storage.SecureStorage
import kotlinx.coroutines.*

/**
 * Foreground service that manages the heartbeat loop.
 *
 * For the MVP, this service runs the 30-second heartbeat loop in
 * the background via a foreground notification. The actual WireGuard
 * tunnel is managed by the stock `wireguard-android` library (or
 * the user's existing WireGuard app); this service is just the
 * heartbeat agent.
 *
 * A future iteration integrates the wireguard-android tunnel
 * directly so the heartbeat and the tunnel lifecycle are unified.
 */
class Wg0VpnService : Service() {
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val api = LiveBrainApi()

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        val notification = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("wg0 connected")
            .setContentText("Heartbeat active")
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .build()
        startForeground(1, notification)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        scope.launch { heartbeatLoop() }
        return START_STICKY
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    private suspend fun heartbeatLoop() {
        while (scope.isActive) {
            try {
                val nodeId = SecureStorage.load(SecureStorage.Key.NODE_ID) ?: break
                val secret = SecureStorage.load(SecureStorage.Key.DEVICE_SECRET) ?: break
                val body = HeartbeatRequest()
                api.heartbeat(nodeId, secret, body)
            } catch (e: Exception) {
                android.util.Log.w("Wg0Heartbeat", "Heartbeat failed: ${e.message}")
            }
            delay(30_000)
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID, "wg0 Tunnel",
                NotificationManager.IMPORTANCE_LOW,
            )
            getSystemService(NotificationManager::class.java)?.createNotificationChannel(channel)
        }
    }

    companion object {
        const val CHANNEL_ID = "wg0_tunnel"
    }
}
