package __PACKAGE__

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews

/** Startbildschirm-Widget: „Frag Junels …“ öffnet einen neuen Chat, das Mikrofon startet ein Gespräch. */
class JunelsWidget : AppWidgetProvider() {
    override fun onUpdate(ctx: Context, mgr: AppWidgetManager, ids: IntArray) {
        for (id in ids) {
            val views = RemoteViews(ctx.packageName, R.layout.junels_widget)
            views.setOnClickPendingIntent(R.id.junels_widget_ask, action(ctx, "newchat", 1))
            views.setOnClickPendingIntent(R.id.junels_widget_mic, action(ctx, "conversation", 2))
            mgr.updateAppWidget(id, views)
        }
    }

    private fun action(ctx: Context, id: String, code: Int): PendingIntent {
        val intent = Intent(ctx, MainActivity::class.java)
            .setAction("junels.widget.$id")
            .putExtra("junels_action", id)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(ctx, code, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }
}
