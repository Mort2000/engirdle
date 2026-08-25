package com.engirdle.native_services

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

/**
 * Translation progress and result notifications (design §9.2/§12.4).
 *
 * The workmanager plugin starts the dataSync foreground service with a
 * static notification computed from the registration-time config. Once the
 * Dart worker runs, it re-posts the SAME notification id with live progress
 * and a cancel action — re-posting under the foreground-service id keeps
 * the service attached while upgrading the content. Result summaries use a
 * DISTINCT id: the system removes the service notification when the worker
 * finishes, which would otherwise swallow the summary.
 *
 * The cancel action launches the app's MainActivity with
 * [ACTION_CANCEL_TRANSLATION]; the activity forwards the job id to Dart,
 * which cancels through the translation module (single code path for
 * on-screen and notification cancels).
 *
 * Notification content never includes article text or translations — the
 * title and unit counts only (§12.4).
 */
object TranslationNotifications {
    const val ACTION_CANCEL_TRANSLATION = "com.engirdle.mobile.action.CANCEL_TRANSLATION"
    const val EXTRA_JOB_ID = "job_id"

    private const val CHANNEL_ID = "engirdle_translation"
    private const val CHANNEL_NAME = "文章翻译"

    fun areEnabled(context: Context): Boolean =
        NotificationManagerCompat.from(context).areNotificationsEnabled()

    /** Live progress under the foreground-service notification id. */
    fun showProgress(context: Context, jobId: String, title: String, done: Int, total: Int) {
        val safeTotal = total.coerceAtLeast(1)
        val notification = baseBuilder(context, "正在翻译：$title")
            .setContentText("$done / $safeTotal")
            .setProgress(safeTotal, done.coerceIn(0, safeTotal), false)
            .setOngoing(true)
            .addAction(0, "取消", cancelPendingIntent(context, jobId))
            .build()
        post(context, notificationId(jobId), notification)
    }

    /** Parked in waiting_retry: posted on the summary id (distinct from the
     *  foreground id — the system removes the service notification when the
     *  worker returns, which would swallow a waiting notice posted under
     *  it), with the same cancel action as the progress notification. */
    fun showWaiting(context: Context, jobId: String, title: String) {
        val notification = baseBuilder(context, "正在翻译：$title")
            .setContentText("网络不稳定，稍后自动继续")
            .setAutoCancel(true)
            .addAction(0, "取消", cancelPendingIntent(context, jobId))
            .build()
        post(context, resultNotificationId(jobId), notification)
    }

    /** Terminal summary on its own id, auto-cancelled on tap. */
    fun showFinished(context: Context, jobId: String, title: String, succeeded: Boolean) {
        val notification = baseBuilder(
            context,
            if (succeeded) "翻译完成：$title" else "翻译失败：$title",
        )
            .setContentText(if (succeeded) "可切换英中/中文模式阅读" else "点按查看详情")
            .setAutoCancel(true)
            .build()
        post(context, resultNotificationId(jobId), notification)
    }

    private fun baseBuilder(context: Context, title: String): NotificationCompat.Builder {
        ensureChannel(context)
        return NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(resolveIcon(context))
            .setContentTitle(title)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
    }

    /** Clears a job's waiting/summary notifications (cancel/pause, §12.4). */
    fun dismiss(context: Context, jobId: String) {
        val manager = NotificationManagerCompat.from(context)
        manager.cancel(notificationId(jobId))
        manager.cancel(resultNotificationId(jobId))
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            CHANNEL_NAME,
            NotificationManager.IMPORTANCE_LOW,
        )
        context.getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    private fun cancelPendingIntent(context: Context, jobId: String): PendingIntent {
        // The main activity is addressed by component name string: this
        // plugin module must not compile against the app module.
        val intent = Intent().setClassName(context.packageName, "${context.packageName}.MainActivity")
            .setAction(ACTION_CANCEL_TRANSLATION)
            .putExtra(EXTRA_JOB_ID, jobId)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        return PendingIntent.getActivity(
            context,
            jobId.hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun resolveIcon(context: Context): Int {
        val applicationIcon = context.applicationInfo.icon
        return if (applicationIcon != 0) applicationIcon else android.R.drawable.ic_dialog_info
    }

    private fun post(context: Context, id: Int, notification: android.app.Notification) {
        // Posting without POST_NOTIFICATIONS granted would throw on 13+;
        // denial hides notifications but never blocks the work (§9.3).
        if (!areEnabled(context)) return
        try {
            NotificationManagerCompat.from(context).notify(id, notification)
        } catch (_: SecurityException) {
            // Permission revoked between check and post.
        }
    }

    // Ids must match the Dart side (background_work.dart): FNV-1a over the
    // job id — String.hashCode differs between Dart and the JVM.
    fun notificationId(jobId: String): Int = 2000 + (fnv1a(jobId) % 500000L).toInt()

    fun resultNotificationId(jobId: String): Int = 10002 + (fnv1a(jobId) % 65536L).toInt()

    private fun fnv1a(value: String): Long {
        var hash = 0x811c9dc5L
        for (byte in value.toByteArray(Charsets.UTF_8)) {
            hash = hash xor ((byte.toInt() and 0xFF).toLong())
            hash = (hash * 0x01000193L) and 0xFFFFFFFFL
        }
        return hash
    }
}
