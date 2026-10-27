package com.huaxu.judging

import android.content.ContentValues
import android.content.Intent
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {

    /// 把文件存进系统相册，返回相册里的 uri 字符串；失败返回 null。
    private fun saveToGallery(path: String?, displayName: String): String? {
        if (path.isNullOrEmpty()) return null
        val src = File(path)
        if (!src.exists()) return null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, displayName)
                put(MediaStore.Images.Media.MIME_TYPE, "image/png")
                put(MediaStore.Images.Media.RELATIVE_PATH,
                    Environment.DIRECTORY_PICTURES + "/之计")
                put(MediaStore.Images.Media.IS_PENDING, 1)
            }
            val resolver = contentResolver
            val uri = resolver.insert(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values
            ) ?: return null
            resolver.openOutputStream(uri)?.use { out ->
                src.inputStream().use { input -> input.copyTo(out) }
            } ?: return null
            values.clear()
            values.put(MediaStore.Images.Media.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            return uri.toString()
        }
        // Android 9 及以下：写公共 Pictures/之计。
        val dir = File(
            Environment.getExternalStoragePublicDirectory(
                Environment.DIRECTORY_PICTURES
            ),
            "之计"
        )
        if (!dir.exists()) dir.mkdirs()
        val dest = File(dir, displayName)
        src.copyTo(dest, overwrite = true)
        // 让相册立即可见
        sendBroadcast(
            Intent(Intent.ACTION_MEDIA_SCANNER_SCAN_FILE).apply {
                data = android.net.Uri.fromFile(dest)
            }
        )
        return dest.absolutePath
    }
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 保存图片到系统相册：Android 10+ 走 MediaStore，9 及以下写公共 Pictures。
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "judging/gallery"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "saveImage" -> {
                    val path = call.argument<String>("path")
                    val name = call.argument<String>("name") ?: "judging.png"
                    try {
                        val saved = saveToGallery(path, name)
                        result.success(saved)
                    } catch (e: Exception) {
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "judging/island"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "islandStatus" -> result.success(FocusIsland.status(this))
                "scheduleIslands" -> {
                    try {
                        val items = org.json.JSONArray(call.argument<String>("items") ?: "[]")
                        FocusIsland.scheduleIslands(this, items)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "cancelIslands" -> {
                    FocusIsland.cancelIslands(this)
                    result.success(true)
                }
                "scheduleTaskLive" -> {
                    try {
                        val items = org.json.JSONArray(call.argument<String>("items") ?: "[]")
                        TaskLiveScheduler.scheduleTaskLive(this, items)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "cancelTaskLive" -> {
                    try {
                        TaskLiveScheduler.cancelTaskLive(this)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "setIslandEnabled" -> {
                    FocusIsland.setEnabled(this, call.argument<Boolean>("enabled") == true)
                    result.success(true)
                }
                "islandEnabled" -> result.success(FocusIsland.isEnabled(this))
                "postIslandTest" -> {
                    val now = System.currentTimeMillis()
                    val param = FocusIsland.parameters(
                        title = call.argument<String>("title") ?: "超级岛测试",
                        bodyText = call.argument<String>("body") ?: "这是一条灵动岛胶囊测试",
                        countdownTargetMillis = now + 10 * 60 * 1000L,
                        nowMillis = now,
                        timeoutSeconds = 600,
                        sequenceValue = now,
                    )
                    result.success(FocusIsland.notifyNow(
                        this, 990002,
                        call.argument<String>("title") ?: "超级岛测试",
                        call.argument<String>("body") ?: "这是一条灵动岛胶囊测试",
                        param, now + 10 * 60 * 1000L,
                    ))
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "judging/share"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "shareImage" -> {
                    try {
                        val path = call.argument<String>("path")
                        val pkg = call.argument<String>("package")
                        val file = File(path)
                        if (!file.exists()) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        val uri = FileProvider.getUriForFile(
                            this,
                            "$packageName.fileprovider",
                            file
                        )
                        val intent = Intent(Intent.ACTION_SEND).apply {
                            type = "image/png"
                            putExtra(Intent.EXTRA_STREAM, uri)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            if (!pkg.isNullOrEmpty()) setPackage(pkg)
                        }
                        if (intent.resolveActivity(packageManager) == null) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "shareTargets" -> {
                    val candidates = listOf(
                        "com.tencent.mm",
                        "com.tencent.mobileqq",
                        "com.sina.weibo"
                    )
                    val installed = candidates.filter { pkg ->
                        try {
                            packageManager.getPackageInfo(pkg, 0)
                            true
                        } catch (e: Exception) {
                            false
                        }
                    }
                    result.success(installed)
                }
                "isIgnoringBatteryOptimizations" -> {
                    val pm = getSystemService(POWER_SERVICE) as android.os.PowerManager
                    result.success(pm.isIgnoringBatteryOptimizations(packageName))
                }
                "requestIgnoreBatteryOptimizations" -> {
                    try {
                        startActivity(Intent(
                            android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                            android.net.Uri.parse("package:$packageName")
                        ))
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "canUseFullScreenIntent" -> {
                    // Android 14+ 全屏意图需用户授权；低版本声明即用。
                    result.success(
                        if (android.os.Build.VERSION.SDK_INT >= 34) {
                            val nm = getSystemService(NOTIFICATION_SERVICE)
                                as android.app.NotificationManager
                            nm.canUseFullScreenIntent()
                        } else true
                    )
                }
                "openExactAlarmSettings" -> {
                    try {
                        startActivity(Intent(
                            android.provider.Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM,
                            android.net.Uri.parse("package:$packageName")
                        ))
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "openNotificationSettings" -> {
                    try {
                        startActivity(Intent(
                            android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS,
                            android.net.Uri.parse("package:$packageName")
                        ))
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "openChannelSettings" -> {
                    try {
                        val channelId = call.argument<String>("channelId") ?: ""
                        startActivity(Intent(
                            android.provider.Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS
                        ).apply {
                            putExtra(android.provider.Settings.EXTRA_APP_PACKAGE, packageName)
                            putExtra(android.provider.Settings.EXTRA_CHANNEL_ID, channelId)
                        })
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "manufacturer" -> result.success(android.os.Build.MANUFACTURER ?: "")
                "openComponent" -> {
                    try {
                        val flat = call.argument<String>("component") ?: ""
                        val cn = android.content.ComponentName.unflattenFromString(flat)
                        if (cn == null) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        val intent = Intent().setComponent(cn)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }
        // 后台保活（无厂商推送方案）：开关、状态与电池优化豁免入口。
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "judging/keepalive"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "startKeepAlive" -> {
                    SyncKeepAliveService.start(
                        this, call.argument<Long>("handle") ?: 0L)
                    result.success(true)
                }
                "stopKeepAlive" -> {
                    SyncKeepAliveService.stop(this)
                    result.success(true)
                }
                "keepAliveEnabled" -> result.success(SyncKeepAliveService.isEnabled(this))
                "showKeepAliveNotice" -> result.success(
                    SyncKeepAliveService.isShowNotice(this))
                "setShowKeepAliveNotice" -> {
                    SyncKeepAliveService.setShowNotice(
                        this, call.argument<Boolean>("show") ?: false)
                    result.success(true)
                }
                "keepAliveNoticeHidden" -> result.success(
                    SyncKeepAliveService.isChannelHidden(this) ||
                        SyncKeepAliveService.isDismissed(this))
                "openKeepAliveChannelSettings" -> result.success(
                    openKeepAliveChannelSettings())
                "resetKeepAliveNotice" -> {
                    SyncKeepAliveService.resetDismissed(this)
                    result.success(true)
                }
                "refreshKeepAlive" -> {
                    SyncKeepAliveService.refresh(this)
                    result.success(true)
                }
                "notificationsEnabled" -> {
                    val nm = getSystemService(android.app.NotificationManager::class.java)
                    result.success(nm?.areNotificationsEnabled() ?: false)
                }
                "isIgnoringBatteryOptimizations" -> {
                    val pm = getSystemService(android.os.PowerManager::class.java)
                    val pkg = packageName
                    result.success(
                        pm?.isIgnoringBatteryOptimizations(pkg) ?: false)
                }
                "openBatterySettings" -> {
                    result.success(openBatteryOptimizationSettings())
                }
                else -> result.notImplemented()
            }
        }
    }

    /** 打开本应用的「后台连接」渠道设置页，让用户自行把提示关掉。 */
    private fun openKeepAliveChannelSettings(): Boolean {
        val candidates = listOf(
            Intent(android.provider.Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
                .putExtra(android.provider.Settings.EXTRA_APP_PACKAGE, packageName)
                .putExtra(android.provider.Settings.EXTRA_CHANNEL_ID,
                    SyncKeepAliveService.ChannelId),
            Intent(android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(android.provider.Settings.EXTRA_APP_PACKAGE, packageName),
            Intent(android.provider.Settings.ACTION_SETTINGS),
        )
        for (intent in candidates) {
            try {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(intent)
                return true
            } catch (_: Exception) {
                // 换下一个候选页。
            }
        }
        return false
    }

    /** 打开「忽略电池优化」请求页；部分 ROM 没有该页面时退到电池设置总页。 */
    private fun openBatteryOptimizationSettings(): Boolean {
        val pkg = packageName
        val candidates = listOf(
            Intent(android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                .setData(android.net.Uri.parse("package:$pkg")),
            Intent(android.provider.Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS),
            Intent(android.provider.Settings.ACTION_SETTINGS),
        )
        for (intent in candidates) {
            try {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(intent)
                return true
            } catch (_: Exception) {
                // 换下一个候选页。
            }
        }
        return false
    }
}
