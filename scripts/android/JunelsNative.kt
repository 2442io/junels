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
            "cancelNotify" -> {
                cancelNote(ctx, call.argument<Int>("id") ?: 0)
                result.success(true)
            }
            "takeNotifyEvents" -> {
                val prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                val arr = JSONArray(prefs.getString("events", "[]"))
                prefs.edit().putString("events", "[]").apply()
                val out = ArrayList<Map<String, Any>>()
                for (i in 0 until arr.length()) {
                    val o = arr.getJSONObject(i)
                    out.add(mapOf("id" to o.getInt("id"), "action" to o.getString("action"), "at" to o.optLong("at")))
                }
                result.success(out)
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
                    val kind = call.argument<String>("kind") ?: "erinnerung"
                    // gleiche id ersetzt (Bündeln/Ruhezeit)
                    val keep = JSONArray()
                    for (i in 0 until arr.length()) if (arr.getJSONObject(i).optInt("id") != id) keep.put(arr.getJSONObject(i))
                    keep.put(JSONObject().put("id", id).put("title", title).put("body", body).put("at", at).put("kind", kind))
                    prefs.edit().putString("notes", keep.toString()).apply()
                    setNoteAlarm(ctx, id, title, body, at, kind)
                } else {
                    notify(ctx, title, body, call.argument<String>("conversation"), id, call.argument<String>("kind"))
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
            setNoteAlarm(ctx, o.getInt("id"), o.getString("title"), o.getString("body"), maxOf(at, now + 5_000), o.optString("kind", "erinnerung"))
        }
        old.edit().putString("notes", keep.toString()).apply()
    }

    fun setNoteAlarm(ctx: Context, id: Int, title: String, body: String, at: Long, kind: String = "erinnerung") {
        val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val i = Intent(ctx, AlarmReceiver::class.java).setAction("junels.NOTIFY")
            .putExtra("nid", id).putExtra("title", title).putExtra("body", body).putExtra("kind", kind)
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

    /** Geplante Meldung entfernen (Wecker + gespeicherte Erinnerung + angezeigte Meldung). */
    fun cancelNote(ctx: Context, id: Int) {
        val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val i = Intent(ctx, AlarmReceiver::class.java).setAction("junels.NOTIFY")
        am.cancel(PendingIntent.getBroadcast(ctx, id, i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
        noteFired(ctx, id)
        (ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(id)
    }

    /** Schlummern/Erledigt aus der Meldung: für die App merken (Postfach gleicht beim Öffnen ab). */
    fun recordEvent(ctx: Context, id: Int, action: String, at: Long) {
        val prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val arr = JSONArray(prefs.getString("events", "[]"))
        arr.put(JSONObject().put("id", id).put("action", action).put("at", at))
        prefs.edit().putString("events", arr.toString()).apply()
    }

    /** Erinnerung um [minutes] verschieben. */
    fun snooze(ctx: Context, id: Int, title: String, body: String, kind: String, minutes: Int) {
        val at = System.currentTimeMillis() + minutes * 60_000L
        (ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(id)
        val prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val arr = JSONArray(prefs.getString("notes", "[]"))
        val keep = JSONArray()
        for (i in 0 until arr.length()) if (arr.getJSONObject(i).optInt("id") != id) keep.put(arr.getJSONObject(i))
        keep.put(JSONObject().put("id", id).put("title", title).put("body", body).put("at", at).put("kind", kind))
        prefs.edit().putString("notes", keep.toString()).apply()
        setNoteAlarm(ctx, id, title, body, at, kind)
        recordEvent(ctx, id, "snooze", at)
    }

    /** Art der Meldung → Kanal, Farbe, Symbol (Konzept „Benachrichtigungen“). */
    private data class Kind(val channel: String, val name: String, val importance: Int, val color: Int, val label: String)

    private fun kindOf(k: String?): Kind = when (k) {
        "aktion" -> Kind("k_aktion", "Aktionen – Junels wartet auf dich", NotificationManager.IMPORTANCE_HIGH, 0xFF7C4FE0.toInt(), "Aktion")
        "warnung" -> Kind("k_warnung", "Warnungen – Fehler und Grenzwerte", NotificationManager.IMPORTANCE_HIGH, 0xFFD14545.toInt(), "Warnung")
        "erinnerung" -> Kind("k_erinnerung", "Erinnerungen", NotificationManager.IMPORTANCE_HIGH, 0xFFB7860B.toInt(), "Erinnerung")
        "ergebnis" -> Kind("k_ergebnis", "Ergebnisse – etwas ist fertig", NotificationManager.IMPORTANCE_DEFAULT, 0xFF119A67.toInt(), "Fertig")
        "ruhig" -> Kind("k_ruhig", "Hintergrund", NotificationManager.IMPORTANCE_MIN, 0xFF8A8F98.toInt(), "Hintergrund")
        else -> Kind("k_info", "Infos – Neues ohne Handlungsbedarf", NotificationManager.IMPORTANCE_LOW, 0xFF2F6BD8.toInt(), "Info")
    }

    /** Großes Symbol: farbiger Kreis mit weißem Symbol der Art. */
    private fun badge(ctx: Context, kind: String, color: Int): android.graphics.Bitmap? = try {
        val res = ctx.resources.getIdentifier("junels_n_$kind", "drawable", ctx.packageName)
        val size = (48 * ctx.resources.displayMetrics.density).toInt()
        val bmp = android.graphics.Bitmap.createBitmap(size, size, android.graphics.Bitmap.Config.ARGB_8888)
        val cv = android.graphics.Canvas(bmp)
        val p = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply { this.color = color }
        cv.drawCircle(size / 2f, size / 2f, size / 2f, p)
        if (res != 0) {
            val d = ctx.getDrawable(res)!!.mutate()
            val pad = size / 4
            d.setBounds(pad, pad, size - pad, size - pad)
            d.setTint(0xFFFFFFFF.toInt())
            d.draw(cv)
        }
        bmp
    } catch (_: Throwable) { null }

    fun notify(ctx: Context, title: String, body: String, conversation: String?, id: Int, kindName: String? = null) {
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val k = kindOf(kindName)
        val kindKey = k.channel.removePrefix("k_")
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(NotificationChannel(k.channel, k.name, k.importance).apply {
                lightColor = k.color
                if (kindKey == "erinnerung") setSound(android.media.RingtoneManager.getDefaultUri(android.media.RingtoneManager.TYPE_NOTIFICATION),
                    android.media.AudioAttributes.Builder().setUsage(android.media.AudioAttributes.USAGE_ALARM).build())
            })
            try { nm.deleteNotificationChannel("results") } catch (_: Throwable) {}
        }
        val launch = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)!!
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        if (conversation != null) launch.putExtra("conversation", conversation)
        val open = PendingIntent.getActivity(ctx, id, launch, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        @Suppress("DEPRECATION")
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(ctx, k.channel) else Notification.Builder(ctx)
        val icon = ctx.resources.getIdentifier("junels_n_$kindKey", "drawable", ctx.packageName)
        b.setContentTitle(title).setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setSmallIcon(if (icon != 0) icon else ctx.applicationInfo.icon)
            .setColor(k.color)
            .setSubText(k.label)
            .setAutoCancel(true).setContentIntent(open)
            .setGroup("junels_$kindKey")
            .setCategory(when (kindKey) {
                "erinnerung" -> Notification.CATEGORY_REMINDER
                "warnung" -> Notification.CATEGORY_ERROR
                "aktion" -> Notification.CATEGORY_STATUS
                else -> Notification.CATEGORY_RECOMMENDATION
            })
        badge(ctx, kindKey, k.color)?.let { b.setLargeIcon(it) }
        if (kindKey == "erinnerung") {
            // Schlummern / Erledigt direkt in der Meldung (funktioniert auch bei geschlossener App)
            fun action(act: String, label: String, req: Int): Notification.Action {
                val i = Intent(ctx, AlarmReceiver::class.java).setAction(act)
                    .putExtra("nid", id).putExtra("title", title).putExtra("body", body).putExtra("kind", kindKey)
                val pi = PendingIntent.getBroadcast(ctx, id * 4 + req, i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
                @Suppress("DEPRECATION")
                return Notification.Action.Builder(null, label, pi).build()
            }
            b.addAction(action("junels.SNOOZE", "Schlummern 10 Min", 1))
            b.addAction(action("junels.SNOOZE_1H", "1 Std", 2))
            b.addAction(action("junels.DONE", "Erledigt", 3))
        }
        try {
            nm.notify(id, b.build())
        } catch (_: SecurityException) {
            // ohne Benachrichtigungs-Erlaubnis
        }
    }
}
