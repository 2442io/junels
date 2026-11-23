package __PACKAGE__

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

// Weckt die App zur geplanten Zeit (oder nach einem Neustart: Wecker neu setzen).
class AlarmReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED, "android.intent.action.MY_PACKAGE_REPLACED" -> JunelsNative.applySchedule(ctx)
            "junels.NOTIFY" -> {
                val id = intent.getIntExtra("nid", 7)
                JunelsNative.notify(ctx, intent.getStringExtra("title") ?: "Junels", intent.getStringExtra("body") ?: "", null, id, intent.getStringExtra("kind"))
                JunelsNative.noteFired(ctx, id)
            }
            "junels.RUN_PROMPT" -> {
                val i = Intent(ctx, AgentService::class.java)
                    .setAction(AgentService.ACTION_RUN)
                    .putExtra("id", intent.getStringExtra("id"))
                    .putExtra("text", "Führe „${intent.getStringExtra("title") ?: "Prompt"}“ aus …")
                if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(i) else ctx.startService(i)
            }
        }
    }
}
