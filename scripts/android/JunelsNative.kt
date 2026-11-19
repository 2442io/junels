package __PACKAGE__

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject

// Gemeinsame Funktionen für den Kanal "junels/background" (App und Hintergrund-Engine):
// Vordergrunddienst, geplante Prompts (Wecker), Benachrichtigungen.
object JunelsNative {
    private const val PREFS = "junels_schedule"

    fun handle(ctx: Context, call: MethodCall, result: MethodChannel.Result): Boolean {
        when (call.method) {
            "start" -> {
                val i = Intent(ctx, AgentService::class.java)
                    .putExtra("text", call.argument<String>("text") ?: "Agent arbeitet …")
                if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(i) else ctx.startService(i)
                result.success(true)
            }
            "stop" -> {
                if (!AgentService.headlessActive) ctx.stopService(Intent(ctx, AgentService::class.java))
                result.success(true)
            }
            "schedule" -> {
                val list = call.argument<List<Map<String, Any>>>("items") ?: emptyList()
                val arr = JSONArray()
                for (m in list) arr.put(JSONObject(m))
                ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString("items", arr.toString()).apply()
                applySchedule(ctx)
                result.success(true)
            }
            "notify" -> {
                val title = call.argument<String>("title") ?: "Junels"
                val body = call.argument<String>("body") ?: ""
                val id = call.argument<Int>("id") ?: 7
                val at = (call.argument<Any>("at") as? Number)?.toLong() ?: 0L
                if (at > System.currentTimeMillis() + 1000) {
                    // Erinnerung: Wecker stellen, bleibt auch nach Neustart erhalten
                    val prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                    val arr = JSONArray(prefs.getString("notes", "[]"))
                    arr.put(JSONObject().put("id", id).put("title", title).put("body", body).put("at", at))
                    prefs.edit().putString("notes", arr.toString()).apply()
                    setNoteAlarm(ctx, id, title, body, at)
                } else {
                    notify(ctx, title, body, call.argument<String>("conversation"), id)
                }
                result.success(true)
            }
            else -> return false
        }
        return true
    }

    /** Setzt die Wecker für alle gespeicherten Termine neu (auch nach Neustart). */
    fun applySchedule(ctx: Context) {
        val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val old = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        // alte Wecker entfernen
        for (id in (old.getStringSet("ids", emptySet()) ?: emptySet())) {
            am.cancel(pending(ctx, id, ""))
        }
        val arr = JSONArray(old.getString("items", "[]"))
        val ids = mutableSetOf<String>()
        val now = System.currentTimeMillis()
        for (k in 0 until arr.length()) {
            val o = arr.getJSONObject(k)
            val id = o.getString("id")
            var at = o.getLong("at")
            if (at < now) at = now + 30_000 // verpasst (z. B. Gerät war aus) → gleich nachholen
            val pi = pending(ctx, id, o.optString("title"))
            var exact = true
            if (Build.VERSION.SDK_INT >= 31) exact = am.canScheduleExactAlarms()
            if (exact) am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
            else am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
            ids.add(id)
        }
        old.edit().putStringSet("ids", ids).apply()
        // geplante Erinnerungen wiederherstellen
        val notes = JSONArray(old.getString("notes", "[]"))
        val keep = JSONArray()
        for (k in 0 until notes.length()) {
            val o = notes.getJSONObject(k)
            val at = o.getLong("at")
            if (at < now - 24 * 3600_000L) continue
            keep.put(o)
            setNoteAlarm(ctx, o.getInt("id"), o.getString("title"), o.getString("body"), maxOf(at, now + 5_000))
        }
        old.edit().putString("notes", keep.toString()).apply()
    }

    fun setNoteAlarm(ctx: Context, id: Int, title: String, body: String, at: Long) {
        val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val i = Intent(ctx, AlarmReceiver::class.java).setAction("junels.NOTIFY")
            .putExtra("nid", id).putExtra("title", title).putExtra("body", body)
        val pi = PendingIntent.getBroadcast(ctx, id, i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        var exact = true
        if (Build.VERSION.SDK_INT >= 31) exact = am.canScheduleExactAlarms()
        if (exact) am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
        else am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
    }

    fun noteFired(ctx: Context, id: Int) {
        val prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val notes = JSONArray(prefs.getString("notes", "[]"))
        val keep = JSONArray()
        for (k in 0 until notes.length()) if (notes.getJSONObject(k).getInt("id") != id) keep.put(notes.getJSONObject(k))
        prefs.edit().putString("notes", keep.toString()).apply()
    }

    private fun pending(ctx: Context, id: String, title: String): PendingIntent {
        val i = Intent(ctx, AlarmReceiver::class.java).setAction("junels.RUN_PROMPT")
            .putExtra("id", id).putExtra("title", title)
        return PendingIntent.getBroadcast(ctx, id.hashCode(), i,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    fun notify(ctx: Context, title: String, body: String, conversation: String?, id: Int) {
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(NotificationChannel("results", "Ergebnisse geplanter Prompts", NotificationManager.IMPORTANCE_DEFAULT))
        }
        val launch = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)!!
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        if (conversation != null) launch.putExtra("conversation", conversation)
        val open = PendingIntent.getActivity(ctx, id, launch, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        @Suppress("DEPRECATION")
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(ctx, "results") else Notification.Builder(ctx)
        val n = b.setContentTitle(title).setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setSmallIcon(ctx.applicationInfo.icon).setAutoCancel(true).setContentIntent(open).build()
        try {
            nm.notify(id, n)
        } catch (_: SecurityException) {
            // ohne Benachrichtigungs-Erlaubnis
        }
    }
}
