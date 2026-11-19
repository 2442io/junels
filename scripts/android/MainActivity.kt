package __PACKAGE__

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// Kanal "junels/background": startet/stoppt den Vordergrunddienst, damit der Agent
// weiterrechnet, wenn die App in den Hintergrund geht.
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "junels/background")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "start" -> {
                            val i = Intent(this, AgentService::class.java)
                                .putExtra("text", call.argument<String>("text") ?: "Agent arbeitet …")
                            if (Build.VERSION.SDK_INT >= 26) startForegroundService(i) else startService(i)
                            result.success(true)
                        }
                        "stop" -> {
                            stopService(Intent(this, AgentService::class.java))
                            result.success(true)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("background", e.message, null)
                }
            }
    }
}
