package com.engirdle.mobile

import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// Extends AudioServiceActivity so the audio_service foreground media Service
// shares the Flutter engine with the activity (design §7.2). This keeps media
// playback alive across screen-off, backgrounding and recents-dismissal.
class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.engirdle.mobile/text_processing",
        ).setMethodCallHandler { call, result ->
            if (call.method != "translate") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val text = call.argument<String>("text")
            if (text == null) {
                result.error("invalid_argument", "text is required", null)
                return@setMethodCallHandler
            }
            result.success(openTextProcessor(text))
        }
    }

    private fun openTextProcessor(text: String): Boolean {
        val processIntent = Intent(Intent.ACTION_PROCESS_TEXT).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_PROCESS_TEXT, text)
            putExtra(Intent.EXTRA_PROCESS_TEXT_READONLY, true)
        }
        val handlers = packageManager.queryIntentActivities(
            processIntent,
            PackageManager.MATCH_DEFAULT_ONLY,
        )
        if (handlers.isEmpty()) return false
        return try {
            startActivity(Intent.createChooser(processIntent, "选择本机翻译应用"))
            true
        } catch (_: ActivityNotFoundException) {
            false
        }
    }
}
