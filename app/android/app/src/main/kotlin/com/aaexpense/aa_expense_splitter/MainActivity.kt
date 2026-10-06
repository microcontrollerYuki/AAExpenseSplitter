package com.aaexpense.aa_expense_splitter

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {

    companion object {
        @JvmStatic
        private var channel: MethodChannel? = null
    }

    /** 最近一次通过「打开方式」传入、待 Flutter 消费的同步文件路径 */
    private var latestImportPath: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        latestImportPath = extractPath(intent)
        super.onCreate(savedInstanceState)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        extractPath(intent)?.let {
            latestImportPath = it
            channel?.invokeMethod("onOpenFile", it)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "aa_expense/open_file"
        )
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialFile" -> result.success(latestImportPath)
                else -> result.notImplemented()
            }
        }
    }

    private fun extractPath(intent: Intent?): String? {
        // 显式 extra 传路径（调试/脚本通道，绕过 intent-filter 的 file URI 限制）
        intent?.getStringExtra("aa_import")?.let {
            return it.takeIf { p -> p.endsWith(".aas", true) }
        }
        if (intent?.action != Intent.ACTION_VIEW) return null
        val uri = intent.data ?: return null
        return when (uri.scheme?.lowercase()) {
            "file" -> uri.path?.takeIf { it.endsWith(".aas", true) }
            "content" -> {
                if (!looksLikeAas(uri)) return null
                try {
                    val input = contentResolver.openInputStream(uri) ?: return null
                    val f = File(cacheDir, "open_${System.currentTimeMillis()}.aas")
                    input.use { ins -> f.outputStream().use { ins.copyTo(it) } }
                    f.absolutePath
                } catch (_: Exception) {
                    null
                }
            }
            else -> null
        }
    }

    /** 按 DISPLAY_NAME 过滤 .aas（我们同时注册了 octet-stream，避免响应其他二进制） */
    private fun looksLikeAas(uri: Uri): Boolean {
        return try {
            val c = contentResolver.query(
                uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null
            ) ?: return false
            c.use {
                if (!it.moveToFirst()) return false
                val name = it.getString(0) ?: return false
                name.endsWith(".aas", true)
            }
        } catch (_: Exception) {
            false
        }
    }
}
