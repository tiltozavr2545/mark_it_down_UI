package com.example.markitdown_ui

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.webkit.MimeTypeMap
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var folderResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "markitdown_ui/markdown_export")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "chooseFolder" -> chooseFolder(result)
                    "write" -> writeMarkdown(call, result)
                    else -> result.notImplemented()
                }
            }
    }

    @Suppress("DEPRECATION")
    private fun chooseFolder(result: MethodChannel.Result) {
        if (folderResult != null) {
            result.error("folder_picker_busy", null, null)
            return
        }
        folderResult = result
        try {
            startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                putExtra(Intent.EXTRA_LOCAL_ONLY, true)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            }, EXPORT_FOLDER_REQUEST)
        } catch (exception: Exception) {
            folderResult = null
            result.error("folder_picker_unavailable", null, null)
        }
    }

    @Deprecated("Activity result callback used by FlutterActivity")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != EXPORT_FOLDER_REQUEST) return
        val result = folderResult
        folderResult = null
        result?.success(if (resultCode == Activity.RESULT_OK) data?.data?.toString() else null)
    }

    private fun writeMarkdown(call: MethodCall, result: MethodChannel.Result) {
        val folder = call.argument<String>("folder")
        val name = call.argument<String>("name")
        val bytes = call.argument<ByteArray>("bytes")
        if (folder == null || name == null || bytes == null) {
            result.error("missing_document", null, null)
            return
        }
        Thread {
            var document: Uri? = null
            try {
                val tree = Uri.parse(folder)
                val parent = DocumentsContract.buildDocumentUriUsingTree(
                    tree, DocumentsContract.getTreeDocumentId(tree)
                )
                // Match the platform's mapping to keep the requested .md extension.
                val mimeType = MimeTypeMap.getSingleton().getMimeTypeFromExtension("md")
                    ?: "application/octet-stream"
                document = DocumentsContract.createDocument(contentResolver, parent, mimeType, name)
                    ?: error("Could not create document")
                val output = contentResolver.openOutputStream(document)
                    ?: error("Could not open document")
                output.use { it.write(bytes) }
                runOnUiThread { result.success(null) }
            } catch (exception: Exception) {
                document?.let {
                    runCatching { DocumentsContract.deleteDocument(contentResolver, it) }
                }
                runOnUiThread { result.error("write_failed", null, null) }
            }
        }.start()
    }

    companion object {
        private const val EXPORT_FOLDER_REQUEST = 5142
    }
}
