package com.huaxu.judging

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.content.edit
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.FlutterException
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 后台保活：常驻静默前台服务 + 一条独立 Dart 引擎。
 *
 * 主引擎（界面）被划掉后，这里的引擎接管长轮询，留言/评价照常弹通知。
 * 不接任何厂商推送，抵达性只靠这条连接 + 精确闹钟兜底。
 */
class SyncKeepAliveService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null
    private var engine: FlutterEngine? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            setEnabledPref(false)
            shutdown()
            return START_NOT_STICKY
        }
        if (intent?.action == ACTION_REFRESH) {
            refresh(lastSyncText())
            return START_STICKY
        }
        // 后台引擎的 Dart 入口句柄由 Dart 侧传进来，存下来供开机自恢复。
        intent?.getLongExtra(ExtraHandle, 0L)?.let { handle ->
            if (handle != 0L) saveHandle(handle)
        }
        setEnabledPref(true)
        startForeground(NOTIFICATION_ID, buildNotification(lastSyncText()))
        acquireWakeLock()
        ensureEngine()
        return START_STICKY
    }

    override fun onDestroy() {
        shutdown()
        super.onDestroy()
    }

    private fun shutdown() {
        releaseWakeLock()
        engine?.destroy()
        engine = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    /**
     * 起一条独立 Flutter 引擎跑 keepAliveEntry：与界面引擎完全解耦，
     * 界面销毁不影响它，所以划掉 App 后长轮询还在。
     */
    private fun ensureEngine() {
        if (engine != null) return
        val handle = loadHandle()
        if (handle == 0L) {
            Log.w(TAG, "no dart entrypoint handle, skip headless engine")
            return
        }
        try {
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(applicationContext)
            loader.ensureInitializationComplete(applicationContext, null)
            val info = FlutterCallbackInformationCompat.lookup(handle) ?: return
            val created = FlutterEngine(applicationContext)
            // 插件（通知、prefs 等）必须在这个引擎里也注册一遍。
            io.flutter.plugins.GeneratedPluginRegistrant.registerWith(created)
            created.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(
                    loader.findAppBundlePath(),
                    info.callbackLibraryPath,
                    info.callbackName,
                ))
            engine = created
            Log.i(TAG, "headless engine started: ${info.callbackName}")
        } catch (t: Throwable) {
            Log.e(TAG, "headless engine failed: ${t.message}", t)
            engine = null
        }
    }

    /** 重发一次前台通知；不需要显示时保持安静，不再打扰。 */
    private fun refresh(lastSync: String) {
        // 用户划掉过或选择不显示：都不要重贴（重贴会立刻重新出现在通知栏）。
        if (isDismissed(this) || !showNoticeNow()) return
        runCatching {
            startForeground(NOTIFICATION_ID, buildNotification(lastSync))
        }
    }

    private fun buildNotification(lastSync: String): Notification {
        val open = PendingIntent.getActivity(
            this, 1,
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        // 用户划掉通知时由系统回调：记一笔，之后不再刷新这条提示。
        val dismissed = PendingIntent.getBroadcast(
            this, 2,
            Intent(this, KeepAliveDismissReceiver::class.java)
                .setAction(ACTION_DISMISSED),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val builder = Notification.Builder(this, ChannelId)
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle("之计正在保持连接")
            .setContentText(if (lastSync.isEmpty()) "新留言会立即提醒你" else "最近同步 $lastSync")
            .setContentIntent(open)
            .setDeleteIntent(dismissed)
            // 不设 ongoing：Android 13+ 允许用户把前台服务通知直接划掉，
            // 划掉后服务继续运行、消息照常送达——这是「隐藏常驻提示」的正规途径。
            // 12 及以下由系统自身约束为不可清除，不是我们能改的。
            .setAutoCancel(false)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setPriority(Notification.PRIORITY_MIN)
        if (Build.VERSION.SDK_INT >= 31) {
            // Android 12+：允许把这条静默通知折叠掉，避免刷屏。
            runCatching {
                builder.setForegroundServiceBehavior(
                    Notification.FOREGROUND_SERVICE_IMMEDIATE)
            }
        }
        return builder.build()
    }

    private fun ensureChannel() {
        val manager = getSystemService(NotificationManager::class.java) ?: return
        // 只用一个渠道。系统会把前台服务通知强制抬到「低」级，App 无法设成
        // 不显示；用户若不想看到它，可在系统设置里关掉这个渠道——关掉后
        // 系统不再显示通知，但前台服务照常运行。
        manager.createNotificationChannel(
            NotificationChannel(
                ChannelId, "后台连接", NotificationManager.IMPORTANCE_MIN).apply {
                description = "保持与伴侣的连接以即时收到留言（可在系统设置里关掉，不影响收消息）"
                setShowBadge(false)
                setSound(null, null)
                enableVibration(false)
                enableLights(false)
            })
        // 清掉早期版本留下的另一个渠道。
        runCatching { manager.deleteNotificationChannel(ChannelIdHidden) }
    }

    /** 是否让用户看见那条「正在保持连接」提示（默认不看）。 */
    private fun showNoticeNow(): Boolean = isShowNotice(this)

    private fun acquireWakeLock() {
        if (wakeLock != null) return
        runCatching {
            val pm = getSystemService(PowerManager::class.java) ?: return
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "judging:keepalive")
                .also { it.setReferenceCounted(false); it.acquire() }
        }
    }

    private fun releaseWakeLock() {
        runCatching { wakeLock?.takeIf { it.isHeld }?.release() }
        wakeLock = null
    }

    private fun setEnabledPref(enabled: Boolean) {
        getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .edit { putBoolean(PrefKey, enabled) }
    }

    private fun lastSyncText(): String {
        val ts = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .getLong("flutter.gd2_last_sync", 0L)
        if (ts <= 0) return ""
        return SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(ts))
    }

    private fun saveHandle(handle: Long) {
        getSharedPreferences(Prefs, Context.MODE_PRIVATE)
            .edit().putLong(ExtraHandle, handle).apply()
    }

    private fun loadHandle(): Long =
        getSharedPreferences(Prefs, Context.MODE_PRIVATE).getLong(ExtraHandle, 0L)

    /** FlutterCallbackInformation 在新版 embedding 里位置有变动，取不到就跳过。 */
    private object FlutterCallbackInformationCompat {
        fun lookup(handle: Long): io.flutter.view.FlutterCallbackInformation? =
            runCatching { io.flutter.view.FlutterCallbackInformation.lookupCallbackInformation(handle) }
                .getOrNull()
    }

    companion object {
        private const val TAG = "ZhijiKeepAlive"
        private const val Prefs = "zhiji_keepalive"
        const val ChannelId = "sync_keepalive_v1"
        const val ChannelIdHidden = "sync_keepalive_hidden_v1"
        const val NOTIFICATION_ID = 20260701
        const val ExtraHandle = "dartEntrypointHandle"
        const val ACTION_STOP = "com.huaxu.judging.STOP_KEEP_ALIVE"
        const val ACTION_REFRESH = "com.huaxu.judging.REFRESH_KEEP_ALIVE"
        const val ACTION_DISMISSED = "com.huaxu.judging.KEEP_ALIVE_DISMISSED"
        const val PrefKey = "flutter.gd2_keep_alive"
        private const val KeyDismissed = "dismissed"

        /** 「是否显示这条提示」放在 Flutter 共享 prefs，跨引擎都能读。 */
        internal object ShowNoticePrefs {
            fun get(context: Context) =
                context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        }

        private const val PrefKeyShowNotice = "flutter.gd2_keepalive_show_notice"

        /** 是否让用户看见提示（默认不看）。 */
        fun isShowNotice(context: Context): Boolean =
            ShowNoticePrefs.get(context).getBoolean(PrefKeyShowNotice, false)

        /** 设置是否显示提示，并立即让服务换渠道重发一次。 */
        fun setShowNotice(context: Context, show: Boolean) {
            ShowNoticePrefs.get(context).edit()
                .putBoolean(PrefKeyShowNotice, show)
                .putBoolean(KeyDismissed, false)
                .apply()
            // 服务在跑就让它按新渠道重发通知。
            runCatching {
                context.startService(Intent(context, SyncKeepAliveService::class.java)
                    .setAction(ACTION_REFRESH))
            }
        }

        /** 用户划掉通知时静默：之后 refresh 不再重弹提示。 */
        fun markDismissed(context: Context) {
            context.getSharedPreferences(Prefs, Context.MODE_PRIVATE)
                .edit().putBoolean(KeyDismissed, true).apply()
        }

        /** 通知是否被用户划掉了（13+ 才能划；更早版本恒为 false）。 */
        fun isDismissed(context: Context): Boolean =
            context.getSharedPreferences(Prefs, Context.MODE_PRIVATE)
                .getBoolean(KeyDismissed, false)

        /** 用户手动重新打开提示（设置页「恢复提示」）。 */
        fun resetDismissed(context: Context) {
            context.getSharedPreferences(Prefs, Context.MODE_PRIVATE)
                .edit().putBoolean(KeyDismissed, false).apply()
        }

        /** 后台连接渠道是否被用户在系统设置里关掉（关掉后服务照跑、不显示通知）。 */
        fun isChannelHidden(context: Context): Boolean {
            val nm = context.getSystemService(NotificationManager::class.java) ?: return false
            val ch = nm.getNotificationChannel(ChannelId) ?: return false
            return ch.importance == NotificationManager.IMPORTANCE_NONE
        }

        fun isEnabled(context: Context): Boolean =
            context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                .getBoolean(PrefKey, true)

        fun start(context: Context, dartHandle: Long = 0L) {
            val intent = Intent(context, SyncKeepAliveService::class.java)
                .putExtra(ExtraHandle, dartHandle)
            runCatching {
                if (Build.VERSION.SDK_INT >= 26) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            }
        }

        fun stop(context: Context) {
            runCatching {
                context.startService(
                    Intent(context, SyncKeepAliveService::class.java).setAction(ACTION_STOP))
            }
        }

        fun refresh(context: Context) {
            runCatching {
                context.startService(
                    Intent(context, SyncKeepAliveService::class.java).setAction(ACTION_REFRESH))
            }
        }

        /** 开机/覆盖安装后自恢复：开关打开且已登录才拉起。 */
        fun restoreIfNeeded(context: Context) {
            val sp = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            if (!sp.getBoolean(PrefKey, true)) return
            val token = sp.getString("flutter.gd2_token", null)
            if (token.isNullOrEmpty()) return
            start(context)
        }
    }
}