package __PACKAGE__

import android.content.Intent
import android.os.Build
import androidx.core.content.FileProvider
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.text.PDFTextStripper
import io.flutter.embedding.android.FlutterActivity
import java.io.File
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// Kanal "junels/background": startet/stoppt den Vordergrunddienst, damit der Agent
// weiterrechnet, wenn die App in den Hintergrund geht.
class MainActivity : FlutterActivity() {
    companion object {
        /** Kanal der sichtbaren App (null, wenn sie nicht läuft) */
        @Volatile var channel: MethodChannel? = null
    }

    private var launchConversation: String? = null
    private var launchAction: String? = null
    private var launchShared: Map<String, Any>? = null
    private var device: MethodChannel? = null

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        launchConversation = intent?.getStringExtra("conversation")
        launchAction = intent?.getStringExtra("junels_action")
        launchShared = JunelsDevice.readShared(applicationContext, intent)
        super.onCreate(savedInstanceState)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        intent.getStringExtra("conversation")?.let { channel?.invokeMethod("openConversation", mapOf("id" to it)) }
        intent.getStringExtra("junels_action")?.let { device?.invokeMethod("launchAction", mapOf("id" to it)) }
        JunelsDevice.readShared(applicationContext, intent)?.let { device?.invokeMethod("shared", it) }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (!JunelsDevice.onActivityResult(applicationContext, requestCode, resultCode, data)) {
            @Suppress("DEPRECATION")
            super.onActivityResult(requestCode, resultCode, data)
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == JunelsDevice.REQ_PERMISSION) JunelsDevice.onPermissionResult()
    }

    override fun onDestroy() {
        channel = null
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val bg = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "junels/background")
        channel = bg
        bg.setMethodCallHandler { call, result ->
                try {
                    if (JunelsNative.handle(this, call, result)) return@setMethodCallHandler
                    when (call.method) {
                        "takeLaunchConversation" -> {
                            result.success(launchConversation)
                            launchConversation = null
                        }
                        "requestNotifyPermission" -> {
                            if (Build.VERSION.SDK_INT >= 33) {
                                requestPermissions(arrayOf("android.permission.POST_NOTIFICATIONS"), 42)
                            }
                            result.success(true)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("background", e.message, null)
                }
            }

        // Kanal "junels/device": E-Mail, WhatsApp, Kalender, Kontakte, Kamera, Teilen, Schnellstart
        val dev = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "junels/device")
        device = dev
        dev.setMethodCallHandler { call, result ->
            when (call.method) {
                "takeLaunch" -> {
                    result.success(mapOf("action" to launchAction, "shared" to launchShared))
                    launchAction = null
                    launchShared = null
                }
                else -> JunelsDevice.handle(this, this, call, result)
            }
        }

        // Kanal "junels/files": PDF-Text lesen, Dateien öffnen und teilen
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "junels/files")
            .setMethodCallHandler { call, result ->
                val path = call.argument<String>("path") ?: ""
                when (call.method) {
                    "openUrl" -> {
                        try {
                            val u = call.argument<String>("url") ?: ""
                            val intent = Intent(Intent.ACTION_VIEW, android.net.Uri.parse(u))
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Throwable) {
                            result.error("url", e.message ?: e.toString(), null)
                        }
                    }
                    "pdfPages" -> Thread {
                        // Seiten als PNG (Vorschau zum Durchblättern) – eingebauter PdfRenderer
                        try {
                            val outDir = File(call.argument<String>("out") ?: cacheDir.path).apply { mkdirs() }
                            val width = call.argument<Int>("width") ?: 960
                            val maxPages = call.argument<Int>("maxPages") ?: 60
                            val paths = ArrayList<String>()
                            android.os.ParcelFileDescriptor.open(File(path), android.os.ParcelFileDescriptor.MODE_READ_ONLY).use { fd ->
                                android.graphics.pdf.PdfRenderer(fd).use { r ->
                                    for (i in 0 until minOf(r.pageCount, maxPages)) {
                                        r.openPage(i).use { page ->
                                            val h = (width.toDouble() * page.height / maxOf(page.width, 1)).toInt()
                                            val bmp = android.graphics.Bitmap.createBitmap(width, h, android.graphics.Bitmap.Config.ARGB_8888)
                                            bmp.eraseColor(android.graphics.Color.WHITE)
                                            page.render(bmp, null, null, android.graphics.pdf.PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                                            val f = File(outDir, "seite-${i + 1}.png")
                                            f.outputStream().use { bmp.compress(android.graphics.Bitmap.CompressFormat.PNG, 90, it) }
                                            bmp.recycle()
                                            paths.add(f.absolutePath)
                                        }
                                    }
                                }
                            }
                            runOnUiThread { result.success(paths) }
                        } catch (e: Throwable) {
                            runOnUiThread { result.error("pdf", e.message ?: e.toString(), null) }
                        }
                    }.start()
                    "pdfText" -> Thread {
                        try {
                            PDFBoxResourceLoader.init(applicationContext)
                            PDDocument.load(File(path)).use { doc ->
                                val pages = doc.numberOfPages
                                val stripper = PDFTextStripper()
                                stripper.startPage = 1
                                stripper.endPage = minOf(pages, call.argument<Int>("maxPages") ?: 300)
                                val text = stripper.getText(doc)
                                runOnUiThread { result.success(mapOf("text" to text, "pages" to pages)) }
                            }
                        } catch (e: Throwable) {
                            runOnUiThread { result.error("pdf", e.message ?: e.toString(), null) }
                        }
                    }.start()
                    "installApk" -> {
                        try {
                            val src = File(path)
                            val dir = File(cacheDir, "shared").apply { mkdirs() }
                            val f = File(dir, "Junels-update.apk")
                            if (src.absolutePath != f.absolutePath) src.copyTo(f, overwrite = true)
                            val uri = FileProvider.getUriForFile(this, "$packageName.files", f)
                            val intent = Intent(Intent.ACTION_VIEW)
                                .setDataAndType(uri, "application/vnd.android.package-archive")
                                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("install", e.message ?: e.toString(), null)
                        }
                    }
                    "open", "share" -> {
                        try {
                            val src = File(path)
                            val dir = File(cacheDir, "shared").apply { mkdirs() }
                            val f = File(dir, src.name)
                            src.copyTo(f, overwrite = true)
                            val uri = FileProvider.getUriForFile(this, "$packageName.files", f)
                            val mime = call.argument<String>("mime") ?: "*/*"
                            val intent = if (call.method == "open") {
                                Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime)
                            } else {
                                Intent(Intent.ACTION_SEND).setType(mime).putExtra(Intent.EXTRA_STREAM, uri)
                            }
                            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            startActivity(Intent.createChooser(intent, if (call.method == "open") "Öffnen mit" else "Teilen"))
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("file", e.message ?: e.toString(), null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
