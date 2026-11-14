package cn.yooss.moodiary

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/** Visible, user-started foreground service for the local LAN workspace.
 * Dart owns the HTTP server while this service keeps the process eligible for
 * background execution. It does not survive a user force-stop or OS kill.
 */
class ModLanForegroundService : Service() {
    companion object {
        const val ACTION_STOP = "cn.yooss.moodiary.mod.STOP_LAN"
        const val CHANNEL_ID = "moodiary_lan_web"
        const val NOTIFICATION_ID = 91220
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            // The Dart server must also be stopped in its owning engine.
            // We do not expose the notification action until it is wired to
            // the same atomic stop path; app screen remains the stop control.
            stopSelf()
            return START_NOT_STICKY
        }
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Moodiary 局域网 Web 服务", NotificationManager.IMPORTANCE_LOW)
        )
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val pending = launch?.let {
            PendingIntent.getActivity(this, 0, it, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        }
        val builder = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("Moodiary Web 服务正在运行")
            .setContentText("局域网访问已开启 · 点击管理和停止")
            .setSmallIcon(android.R.drawable.ic_menu_info_details)
            .setOngoing(true)
        if (pending != null) builder.setContentIntent(pending)
        val notification = builder.build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        return START_NOT_STICKY
    }
}
