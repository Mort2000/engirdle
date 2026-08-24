package com.engirdle.mobile

import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.OpenableColumns
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

// Extends AudioServiceActivity so the audio_service foreground media Service
// shares the Flutter engine with the activity (design §7.2). This keeps media
// playback alive across screen-off, backgrounding and recents-dismissal.
class MainActivity : AudioServiceActivity() {
    // Content URIs are not stable across process restarts; the import module
    // reads the bytes inside pickDocument and never persists the grant, so a
    // member holds the pending result only for the lifetime of one pick.
    private var pendingDocumentResult: MethodChannel.Result? = null

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

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.engirdle.mobile/documents",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "pickDocument" -> pickDocument(result)
                "readBytes" -> readBytes(call.argument<String>("uri"), result)
                else -> result.notImplemented()
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != PICK_DOCUMENT_REQUEST) return
        val pending = pendingDocumentResult ?: return
        pendingDocumentResult = null
        val uri = data?.data
        if (uri == null) {
            pending.success(null)
            return
        }
        val name = queryDisplayName(uri)
        val mime = contentResolver.getType(uri)
        pending.success(mapOf("uri" to uri.toString(), "name" to name, "mime" to mime))
    }

    private fun pickDocument(result: MethodChannel.Result) {
        if (pendingDocumentResult != null) {
            result.error("pick_in_progress", "a picker is already open", null)
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(
                Intent.EXTRA_MIME_TYPES,
                arrayOf(
                    "text/plain",
                    "text/markdown",
                    "text/x-markdown",
                    "application/zip",
                    "application/octet-stream",
                ),
            )
        }
        pendingDocumentResult = result
        try {
            @Suppress("DEPRECATION")
            startActivityForResult(intent, PICK_DOCUMENT_REQUEST)
        } catch (_: ActivityNotFoundException) {
            pendingDocumentResult = null
            result.error("no_picker", "no document picker is available", null)
        }
    }

    private fun readBytes(uriString: String?, result: MethodChannel.Result) {
        if (uriString == null) {
            result.error("invalid_argument", "uri is required", null)
            return
        }
        val uri = Uri.parse(uriString)
        try {
            contentResolver.openInputStream(uri)?.use { input ->
                val buffer = ByteArrayOutputStream()
                input.copyTo(buffer)
                result.success(buffer.toByteArray())
            } ?: result.error("unreadable", "could not open $uriString", null)
        } catch (e: Exception) {
            result.error("unreadable", "could not read $uriString: ${e.message}", null)
        }
    }

    private fun queryDisplayName(uri: Uri): String? =
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { cursor ->
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0 && cursor.moveToFirst()) cursor.getString(index) else null
            }

    companion object {
        private const val PICK_DOCUMENT_REQUEST = 4102
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
