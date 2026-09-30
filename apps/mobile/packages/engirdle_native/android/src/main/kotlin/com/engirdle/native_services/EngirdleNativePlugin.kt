package com.engirdle.native_services

import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodChannel

/**
 * Native services shared by every Flutter engine (lightweight-readpack
 * design §9.2): the main UI engine AND the headless engine WorkManager
 * spawns for the translation worker.
 *
 * This is a real plugin (not a channel registered in MainActivity) exactly
 * because MainActivity channels only exist on the activity's engine — the
 * background engine needs the Keystore secret store to read the translation
 * API key unattended (§10.1), and posts its progress notifications itself.
 */
class EngirdleNativePlugin : FlutterPlugin, ActivityAware {
    private var appContext: Context? = null
    private var activity: Activity? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        val secrets = SecretStore(binding.applicationContext)

        MethodChannel(binding.binaryMessenger, "engirdle.native/secrets")
            .setMethodCallHandler { call, result ->
                val alias = call.argument<String>("alias")
                if (alias.isNullOrEmpty()) {
                    result.error("invalid_argument", "alias is required", null)
                    return@setMethodCallHandler
                }
                try {
                    when (call.method) {
                        "read" -> result.success(secrets.read(alias))
                        "write" -> {
                            val secret = call.argument<String>("secret")
                            if (secret.isNullOrEmpty()) {
                                result.error("invalid_argument", "secret is required", null)
                            } else {
                                secrets.write(alias, secret)
                                result.success(null)
                            }
                        }
                        "delete" -> {
                            secrets.delete(alias)
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("secret_store", e.message, null)
                }
            }

        MethodChannel(binding.binaryMessenger, "engirdle.native/translation_notifications")
            .setMethodCallHandler { call, result ->
                val context = appContext
                if (context == null) {
                    result.error("no_context", "engine detached", null)
                    return@setMethodCallHandler
                }
                fun requireJobId(): String? {
                    val jobId = call.argument<String>("jobId")
                    if (jobId == null) {
                        result.error("invalid_argument", "jobId is required", null)
                    }
                    return jobId
                }
                try {
                    when (call.method) {
                        "progress" -> {
                            val jobId = requireJobId() ?: return@setMethodCallHandler
                            TranslationNotifications.showProgress(
                                context,
                                jobId = jobId,
                                title = call.argument<String>("title") ?: "",
                                done = call.argument<Int>("done") ?: 0,
                                total = call.argument<Int>("total") ?: 0,
                            )
                            result.success(null)
                        }
                        "waiting" -> {
                            val jobId = requireJobId() ?: return@setMethodCallHandler
                            TranslationNotifications.showWaiting(
                                context,
                                jobId = jobId,
                                title = call.argument<String>("title") ?: "",
                            )
                            result.success(null)
                        }
                        "finished" -> {
                            val jobId = requireJobId() ?: return@setMethodCallHandler
                            TranslationNotifications.showFinished(
                                context,
                                jobId = jobId,
                                title = call.argument<String>("title") ?: "",
                                succeeded = call.argument<Boolean>("succeeded") ?: false,
                            )
                            result.success(null)
                        }
                        "dismiss" -> {
                            val jobId = requireJobId() ?: return@setMethodCallHandler
                            TranslationNotifications.dismiss(context, jobId)
                            result.success(null)
                        }
                        "areEnabled" ->
                            result.success(TranslationNotifications.areEnabled(context))
                        "requestPermission" -> {
                            requestNotificationPermission()
                            // Best-effort fire-and-forget: the system dialog
                            // resolves asynchronously; callers re-query with
                            // areEnabled (the translation runs regardless,
                            // §9.3 — denial hides notifications, it never
                            // blocks work).
                            result.success(TranslationNotifications.areEnabled(context))
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("notifications", e.message, null)
                }
            }
    }

    private fun requestNotificationPermission() {
        val current = activity ?: return
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        if (ContextCompat.checkSelfPermission(
                current,
                android.Manifest.permission.POST_NOTIFICATIONS,
            ) == PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        ActivityCompat.requestPermissions(
            current,
            arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
            REQUEST_POST_NOTIFICATIONS,
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    companion object {
        private const val REQUEST_POST_NOTIFICATIONS = 4201
    }
}
