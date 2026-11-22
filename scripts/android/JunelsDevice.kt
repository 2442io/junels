package __PACKAGE__

import android.Manifest
import android.app.Activity
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.CalendarContract
import android.provider.ContactsContract
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

// Kanal "junels/device": E-Mail, WhatsApp, Telefon, Kalender, Kontakte, Kamera,
// Ordner überwachen, Schnellstart-Knöpfe. Senden/Anrufen/Speichern bestätigt immer
// der Nutzer in der jeweiligen App – Junels bereitet nur vor.
object JunelsDevice {
    private var netCallback: android.net.ConnectivityManager.NetworkCallback? = null

    /** Ist das Gerät online (Internet bestätigt oder zumindest verbunden)? */
    fun isOnline(ctx: Context): Boolean {
        val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as android.net.ConnectivityManager
        val caps = cm.getNetworkCapabilities(cm.activeNetwork ?: return false) ?: return false
        return caps.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
            (Build.VERSION.SDK_INT < 23 || caps.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_VALIDATED))
    }

    fun watchNetwork(ctx: Context, onChange: (Boolean) -> Unit) {
        val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as android.net.ConnectivityManager
        netCallback?.let { try { cm.unregisterNetworkCallback(it) } catch (_: Throwable) {} }
        val cb = object : android.net.ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: android.net.Network) = onChange(isOnline(ctx))
            override fun onLost(network: android.net.Network) = onChange(isOnline(ctx))
            override fun onCapabilitiesChanged(network: android.net.Network, caps: android.net.NetworkCapabilities) = onChange(isOnline(ctx))
        }
        try {
            cm.registerDefaultNetworkCallback(cb)
            netCallback = cb
        } catch (_: Throwable) {}
    }

    const val REQ_PERMISSION = 7301
    const val REQ_PHOTO = 7302
    const val REQ_FOLDER = 7303

    var pending: MethodChannel.Result? = null
    var pendingPermission: Pair<String, () -> Unit>? = null
    var photoPath: String? = null

    private val main = Handler(Looper.getMainLooper())

    private fun start(ctx: Context, intent: Intent) {
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        ctx.startActivity(intent)
    }

    private fun granted(ctx: Context, perm: String) =
        androidx.core.content.ContextCompat.checkSelfPermission(ctx, perm) == PackageManager.PERMISSION_GRANTED

    /** Berechtigung anfragen (nur mit sichtbarer App) und danach [then] ausführen. */
    private fun withPermission(ctx: Context, activity: Activity?, perm: String, result: MethodChannel.Result, then: () -> Unit) {
        if (granted(ctx, perm)) return then()
        if (activity == null) {
            result.error("permission", "Berechtigung fehlt – bitte einmal in der App erlauben", null)
            return
        }
        pendingPermission = Pair(perm) {
            if (granted(ctx, perm)) then() else result.error("permission", "Berechtigung wurde nicht erteilt", null)
        }
        androidx.core.app.ActivityCompat.requestPermissions(activity, arrayOf(perm), REQ_PERMISSION)
    }

    fun onPermissionResult() {
        val p = pendingPermission ?: return
        pendingPermission = null
        p.second()
    }

    fun onActivityResult(ctx: Context, requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        val r = pending
        when (requestCode) {
            REQ_PHOTO -> {
                pending = null
                val p = photoPath
                photoPath = null
                if (resultCode == Activity.RESULT_OK && p != null && File(p).length() > 0) r?.success(p) else r?.success(null)
                return true
            }
            REQ_FOLDER -> {
                pending = null
                val uri = data?.data
                if (resultCode != Activity.RESULT_OK || uri == null) {
                    r?.success(null)
                } else {
                    try {
                        ctx.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    } catch (_: Exception) {}
                    r?.success(mapOf("id" to uri.toString(), "name" to (uri.lastPathSegment ?: uri.toString())))
                }
                return true
            }
        }
        return false
    }

    fun handle(ctx: Context, activity: Activity?, call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "networkStatus" -> result.success(isOnline(ctx))
                // Tresor: Geheimnisse (Passwörter, Tokens) mit einem Schlüssel aus dem Android-Keystore verschlüsselt
                "vaultSet" -> {
                    Vault.put(ctx, call.argument<String>("key") ?: "", call.argument<String>("value"))
                    result.success(true)
                }
                "vaultGet" -> result.success(Vault.get(ctx, call.argument<String>("key") ?: ""))
                "vaultKeys" -> result.success(Vault.keys(ctx))
                "composeEmail" -> {
                    val to = call.argument<String>("to") ?: ""
                    val intent = Intent(Intent.ACTION_SENDTO, Uri.parse("mailto:"))
                    if (to.isNotBlank()) intent.putExtra(Intent.EXTRA_EMAIL, arrayOf(to))
                    intent.putExtra(Intent.EXTRA_SUBJECT, call.argument<String>("subject") ?: "")
                    intent.putExtra(Intent.EXTRA_TEXT, call.argument<String>("body") ?: "")
                    start(ctx, Intent.createChooser(intent, "E-Mail schreiben mit"))
                    result.success(true)
                }
                "whatsapp" -> {
                    val phone = (call.argument<String>("phone") ?: "").filter { it.isDigit() }
                    val text = Uri.encode(call.argument<String>("text") ?: "")
                    start(ctx, Intent(Intent.ACTION_VIEW, Uri.parse("https://wa.me/$phone?text=$text")))
                    result.success(true)
                }
                "dial" -> {
                    val n = call.argument<String>("number") ?: ""
                    start(ctx, Intent(Intent.ACTION_DIAL, Uri.parse("tel:" + Uri.encode(n))))
                    result.success(true)
                }
                "calendarInsert" -> {
                    val intent = Intent(Intent.ACTION_INSERT).setData(CalendarContract.Events.CONTENT_URI)
                        .putExtra(CalendarContract.Events.TITLE, call.argument<String>("title") ?: "")
                        .putExtra(CalendarContract.Events.EVENT_LOCATION, call.argument<String>("location") ?: "")
                        .putExtra(CalendarContract.Events.DESCRIPTION, call.argument<String>("notes") ?: "")
                        .putExtra(CalendarContract.EXTRA_EVENT_BEGIN_TIME, (call.argument<Number>("begin") ?: 0).toLong())
                        .putExtra(CalendarContract.EXTRA_EVENT_END_TIME, (call.argument<Number>("end") ?: 0).toLong())
                        .putExtra(CalendarContract.EXTRA_EVENT_ALL_DAY, call.argument<Boolean>("allDay") ?: false)
                    start(ctx, intent)
                    result.success(true)
                }
                "calendarList" -> withPermission(ctx, activity, Manifest.permission.READ_CALENDAR, result) {
                    Thread {
                        try {
                            val from = (call.argument<Number>("from") ?: 0).toLong()
                            val to = (call.argument<Number>("to") ?: 0).toLong()
                            val b = CalendarContract.Instances.CONTENT_URI.buildUpon()
                            ContentUris.appendId(b, from)
                            ContentUris.appendId(b, to)
                            val out = ArrayList<Map<String, Any?>>()
                            ctx.contentResolver.query(
                                b.build(),
                                arrayOf(
                                    CalendarContract.Instances.TITLE, CalendarContract.Instances.BEGIN,
                                    CalendarContract.Instances.END, CalendarContract.Instances.ALL_DAY,
                                    CalendarContract.Instances.EVENT_LOCATION, CalendarContract.Instances.CALENDAR_DISPLAY_NAME,
                                    CalendarContract.Instances.DESCRIPTION, CalendarContract.Instances.ORGANIZER
                                ),
                                null, null, CalendarContract.Instances.BEGIN + " ASC"
                            )?.use { c ->
                                while (c.moveToNext() && out.size < 100) {
                                    out.add(mapOf(
                                        "title" to (c.getString(0) ?: ""), "begin" to c.getLong(1), "end" to c.getLong(2),
                                        "allDay" to (c.getInt(3) == 1), "location" to (c.getString(4) ?: ""),
                                        "calendar" to (c.getString(5) ?: ""),
                                        "notes" to ((c.getString(6) ?: "") + (if (c.getString(7).isNullOrBlank()) "" else "\nOrganisator: " + c.getString(7)))
                                    ))
                                }
                            }
                            main.post { result.success(out) }
                        } catch (e: Throwable) {
                            main.post { result.error("calendar", e.message ?: e.toString(), null) }
                        }
                    }.start()
                }
                "contacts" -> withPermission(ctx, activity, Manifest.permission.READ_CONTACTS, result) {
                    Thread {
                        try {
                            val q = call.argument<String>("query") ?: ""
                            val people = LinkedHashMap<String, MutableMap<String, Any>>()
                            fun entry(name: String): MutableMap<String, Any> = people.getOrPut(name) {
                                mutableMapOf("name" to name, "phones" to ArrayList<String>(), "emails" to ArrayList<String>())
                            }
                            ctx.contentResolver.query(
                                Uri.withAppendedPath(ContactsContract.CommonDataKinds.Phone.CONTENT_FILTER_URI, Uri.encode(q)),
                                arrayOf(ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME, ContactsContract.CommonDataKinds.Phone.NUMBER),
                                null, null, null
                            )?.use { c ->
                                while (c.moveToNext() && people.size < 10) {
                                    @Suppress("UNCHECKED_CAST")
                                    val l = entry(c.getString(0) ?: "?")["phones"] as ArrayList<String>
                                    val n = c.getString(1) ?: ""
                                    if (n.isNotBlank() && !l.contains(n)) l.add(n)
                                }
                            }
                            ctx.contentResolver.query(
                                Uri.withAppendedPath(ContactsContract.CommonDataKinds.Email.CONTENT_FILTER_URI, Uri.encode(q)),
                                arrayOf(ContactsContract.CommonDataKinds.Email.DISPLAY_NAME_PRIMARY, ContactsContract.CommonDataKinds.Email.ADDRESS),
                                null, null, null
                            )?.use { c ->
                                while (c.moveToNext() && people.size < 10) {
                                    @Suppress("UNCHECKED_CAST")
                                    val l = entry(c.getString(0) ?: "?")["emails"] as ArrayList<String>
                                    val n = c.getString(1) ?: ""
                                    if (n.isNotBlank() && !l.contains(n)) l.add(n)
                                }
                            }
                            main.post { result.success(ArrayList(people.values)) }
                        } catch (e: Throwable) {
                            main.post { result.error("contacts", e.message ?: e.toString(), null) }
                        }
                    }.start()
                }
                "takePhoto" -> {
                    if (activity == null) return result.error("photo", "App nicht sichtbar", null)
                    val dir = File(ctx.cacheDir, "shared").apply { mkdirs() }
                    val f = File(dir, "Foto_${System.currentTimeMillis()}.jpg")
                    val uri = FileProvider.getUriForFile(ctx, ctx.packageName + ".files", f)
                    val intent = Intent(android.provider.MediaStore.ACTION_IMAGE_CAPTURE)
                        .putExtra(android.provider.MediaStore.EXTRA_OUTPUT, uri)
                        .addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    pending = result
                    photoPath = f.absolutePath
                    @Suppress("DEPRECATION")
                    activity.startActivityForResult(intent, REQ_PHOTO)
                }
                "pickFolder" -> {
                    if (activity == null) return result.error("folder", "App nicht sichtbar", null)
                    pending = result
                    @Suppress("DEPRECATION")
                    activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), REQ_FOLDER)
                }
                "scanFolder" -> Thread {
                    try {
                        val tree = Uri.parse(call.argument<String>("id") ?: "")
                        val since = (call.argument<Number>("since") ?: 0).toLong()
                        val outDir = File(ctx.cacheDir, "watch").apply { mkdirs() }
                        val out = ArrayList<Map<String, Any>>()
                        fun walk(docId: String, depth: Int) {
                            val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, docId)
                            ctx.contentResolver.query(
                                children,
                                arrayOf(
                                    DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                                    DocumentsContract.Document.COLUMN_MIME_TYPE, DocumentsContract.Document.COLUMN_LAST_MODIFIED
                                ), null, null, null
                            )?.use { c ->
                                while (c.moveToNext() && out.size < 30) {
                                    val id = c.getString(0)
                                    val name = c.getString(1) ?: ""
                                    val mime = c.getString(2) ?: ""
                                    val mod = c.getLong(3)
                                    val lower = name.lowercase()
                                    val wanted = lower.endsWith(".pdf") || lower.endsWith(".txt") || lower.endsWith(".md")
                                    if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                                        if (depth < 2) walk(id, depth + 1)
                                    } else if (name.isNotEmpty() && mod > since && wanted) {
                                        val f = File(outDir, name)
                                        val input = ctx.contentResolver.openInputStream(DocumentsContract.buildDocumentUriUsingTree(tree, id))
                                        if (input != null) {
                                            input.use { inp -> f.outputStream().use { inp.copyTo(it) } }
                                            out.add(mapOf("path" to f.absolutePath, "name" to name, "modified" to mod))
                                        }
                                    }
                                }
                            }
                        }
                        walk(DocumentsContract.getTreeDocumentId(tree), 0)
                        main.post { result.success(out) }
                    } catch (e: Throwable) {
                        main.post { result.error("folder", e.message ?: e.toString(), null) }
                    }
                }.start()
                "setQuickActions" -> {
                    if (Build.VERSION.SDK_INT >= 26) {
                        val sm = ctx.getSystemService(ShortcutManager::class.java)
                        val items = call.argument<List<Map<String, String>>>("items") ?: emptyList()
                        val max = sm.maxShortcutCountPerActivity
                        sm.setDynamicShortcuts(items.take(max).mapIndexed { i, m -> shortcut(ctx, m["id"] ?: "", m["label"] ?: "", i) })
                    }
                    result.success(true)
                }
                "pinQuickAction" -> {
                    if (Build.VERSION.SDK_INT >= 26) {
                        val sm = ctx.getSystemService(ShortcutManager::class.java)
                        if (sm.isRequestPinShortcutSupported) {
                            sm.requestPinShortcut(shortcut(ctx, call.argument<String>("id") ?: "", call.argument<String>("label") ?: "", 0), null)
                            result.success(true)
                            return
                        }
                    }
                    result.success(false)
                }
                else -> result.notImplemented()
            }
        } catch (e: Throwable) {
            result.error("device", e.message ?: e.toString(), null)
        }
    }

    @androidx.annotation.RequiresApi(26)
    private fun shortcut(ctx: Context, id: String, label: String, rank: Int): ShortcutInfo {
        val intent = Intent(ctx, MainActivity::class.java)
            .setAction(Intent.ACTION_VIEW)
            .putExtra("junels_action", id)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val icon = if (id == "conversation") android.R.drawable.ic_btn_speak_now
            else if (id == "newchat") android.R.drawable.ic_input_add
            else android.R.drawable.ic_media_play
        return ShortcutInfo.Builder(ctx, "junels_" + id.replace(":", "_"))
            .setShortLabel(label.take(24))
            .setLongLabel(label.take(40))
            .setIcon(Icon.createWithResource(ctx, icon))
            .setIntent(intent)
            .setRank(rank)
            .build()
    }

    /** Geteilte Inhalte (Text, Links, Fotos, PDFs) aus einem SEND-Intent auslesen. */
    fun readShared(ctx: Context, intent: Intent?): Map<String, Any>? {
        if (intent == null) return null
        val action = intent.action ?: return null
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) return null
        val text = listOfNotNull(intent.getStringExtra(Intent.EXTRA_SUBJECT), intent.getStringExtra(Intent.EXTRA_TEXT))
            .filter { it.isNotBlank() }.joinToString("\n")
        val uris = ArrayList<Uri>()
        if (action == Intent.ACTION_SEND) {
            @Suppress("DEPRECATION")
            val one: Uri? = intent.getParcelableExtra(Intent.EXTRA_STREAM)
            if (one != null) uris.add(one)
        } else {
            @Suppress("DEPRECATION")
            val many: ArrayList<Uri>? = intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
            if (many != null) uris.addAll(many)
        }
        val dir = File(ctx.cacheDir, "shared_in").apply { mkdirs() }
        val files = ArrayList<Map<String, String>>()
        for (u in uris.take(10)) {
            try {
                var name = "Datei_${System.currentTimeMillis()}"
                ctx.contentResolver.query(u, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                    if (c.moveToFirst()) c.getString(0)?.let { name = it }
                }
                if (!name.contains('.')) {
                    val mime = ctx.contentResolver.getType(u) ?: ""
                    name += when {
                        mime.contains("pdf") -> ".pdf"
                        mime.contains("png") -> ".png"
                        mime.startsWith("image/") -> ".jpg"
                        else -> ".txt"
                    }
                }
                val f = File(dir, name)
                ctx.contentResolver.openInputStream(u)?.use { input -> f.outputStream().use { input.copyTo(it) } }
                files.add(mapOf("path" to f.absolutePath, "name" to name))
            } catch (_: Exception) {}
        }
        if (text.isBlank() && files.isEmpty()) return null
        return mapOf("text" to text, "files" to files)
    }
}


/** Tresor: AES-GCM mit Schlüssel im Android-Keystore (verlässt die Hardware nicht), Daten in SharedPreferences. */
object Vault {
    private const val ALIAS = "junels_vault"
    private const val PREFS = "junels_vault"

    private fun key(): javax.crypto.SecretKey {
        val ks = java.security.KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getEntry(ALIAS, null) as? java.security.KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val gen = javax.crypto.KeyGenerator.getInstance(android.security.keystore.KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            android.security.keystore.KeyGenParameterSpec.Builder(
                ALIAS,
                android.security.keystore.KeyProperties.PURPOSE_ENCRYPT or android.security.keystore.KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(android.security.keystore.KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(android.security.keystore.KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return gen.generateKey()
    }

    fun put(ctx: Context, k: String, v: String?) {
        val prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (v == null) {
            prefs.edit().remove(k).apply()
            return
        }
        val c = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
        c.init(javax.crypto.Cipher.ENCRYPT_MODE, key())
        val enc = c.doFinal(v.toByteArray(Charsets.UTF_8))
        val blob = android.util.Base64.encodeToString(c.iv + enc, android.util.Base64.NO_WRAP)
        prefs.edit().putString(k, blob).apply()
    }

    fun get(ctx: Context, k: String): String? {
        val blob = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(k, null) ?: return null
        return try {
            val raw = android.util.Base64.decode(blob, android.util.Base64.NO_WRAP)
            val c = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
            c.init(javax.crypto.Cipher.DECRYPT_MODE, key(), javax.crypto.spec.GCMParameterSpec(128, raw, 0, 12))
            String(c.doFinal(raw, 12, raw.size - 12), Charsets.UTF_8)
        } catch (e: Exception) {
            null
        }
    }

    fun keys(ctx: Context): List<String> = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).all.keys.toList()
}
