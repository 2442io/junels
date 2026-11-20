package __PACKAGE__

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

// Vordergrunddienst mit dezenter Benachrichtigung und Wake-Lock: hält den Prozess
// am Leben und die CPU wach, solange der Agent antwortet oder ein Download läuft.
class AgentService : Service() {
    companion object {
        const val ACTION_RUN = "junels.SERVICE_RUN_PROMPT"
        /** true, solange eine Hintergrund-Engine einen geplanten Prompt ausführt */
        @Volatile var headlessActive = false
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var headless: FlutterEngine? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val text = intent?.getStringExtra("text") ?: "Agent arbeitet …"
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(
                NotificationChannel("agent", "Agent im Hintergrund", NotificationManager.IMPORTANCE_LOW)
            )
        }
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val open = PendingIntent.getActivity(this, 0, launch, PendingIntent.FLAG_IMMUTABLE)
        @Suppress("DEPRECATION")
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, "agent") else Notification.Builder(this)
        val n = builder
            .setContentTitle("Junels")
            .setContentText(text)
            .setSmallIcon(applicationInfo.icon)
            .setOngoing(true)
            .setContentIntent(open)
            .build()
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(1, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(1, n)
        }
        if (wakeLock == null) {
            val pm = getSystemService(POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "junels:agent").apply {
                setReferenceCounted(false)
                acquire(2 * 60 * 60 * 1000L)
            }
        }
        if (intent?.action == ACTION_RUN) runPrompt(intent.getStringExtra("id") ?: "")
        return START_NOT_STICKY
    }

    /** Geplanten Prompt ausführen: in der laufenden App oder in einer eigenen Hintergrund-Engine. */
    private fun runPrompt(id: String) {
        val main = Handler(Looper.getMainLooper())
        main.post {
            val ui = MainActivity.channel
            if (ui != null) {
                ui.invokeMethod("runPrompt", mapOf("id" to id))
                return@post
            }
            if (headless != null) return@post
            headlessActive = true
            val engine = FlutterEngine(applicationContext)
            headless = engine
            val ch = MethodChannel(engine.dartExecutor.binaryMessenger, "junels/background")
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "getTask" -> result.success(id)
                    "finished" -> {
                        result.success(true)
                        main.postDelayed({ stopHeadless() }, 500)
                    }
                    else -> if (!JunelsNative.handle(applicationContext, call, result)) result.notImplemented()
                }
            }
            // Kalender/Kontakte auch für geplante Prompts (z. B. Morgen-Übersicht)
            MethodChannel(engine.dartExecutor.binaryMessenger, "junels/device").setMethodCallHandler { call, result ->
                JunelsDevice.handle(applicationContext, null, call, result)
            }
            val loader = FlutterInjector.instance().flutterLoader()
            engine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "backgroundMain"))
            // Sicherheitsnetz: nach 45 Minuten beenden
            main.postDelayed({ if (headless === engine) stopHeadless() }, 45 * 60 * 1000L)
        }
    }

    private fun stopHeadless() {
        headless?.destroy()
        headless = null
        headlessActive = false
        stopSelf()
    }

    override fun onDestroy() {
        headless?.destroy()
        headless = null
        headlessActive = false
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        super.onDestroy()
    }
}
