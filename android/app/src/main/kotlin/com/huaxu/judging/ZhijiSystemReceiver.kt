package com.huaxu.judging

import android.app.AlarmManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * 系统状态自愈：
 * - 精确闹钟权限被撤销时系统会清空本应用全部 exact 闹钟——写标记，
 *   下次启动 Dart 侧读取后强制重排。
 * - 开机/覆盖安装后重建超级岛闹钟。
 */
class ZhijiSystemReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            AlarmManager.ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED -> {
                context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                    .edit().putBoolean("flutter.gd2_exact_reschedule_needed", true).apply()
            }
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            -> {
                FocusIsland.restoreFromPrefs(context)
                TaskLiveScheduler.restoreFromPrefs(context)
                // 保活连接与兜底闹钟：开机/升级后都要能自己爬起来。
                SyncKeepAliveService.restoreIfNeeded(context)
            }
        }
    }
}
