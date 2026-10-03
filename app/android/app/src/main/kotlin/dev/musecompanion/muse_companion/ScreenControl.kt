package dev.musecompanion.muse_companion

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.accessibilityservice.GestureDescription
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Path
import android.graphics.Rect
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.provider.Settings
import android.view.Display
import android.view.WindowManager
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import androidx.annotation.RequiresApi
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executor
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * User-enabled screen control. The person turns this on in system
 * Accessibility settings. It can read the screen, screenshot it, tap,
 * swipe, and type. It does not run a shell and it does not grant itself.
 */
class MuseAccessibilityService : AccessibilityService() {
    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        val info = serviceInfo ?: return
        info.flags = info.flags or
            AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS or
            AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
        info.notificationTimeout = 100
        serviceInfo = info
    }

    override fun onUnbind(intent: Intent?): Boolean {
        if (instance === this) instance = null
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        super.onDestroy()
    }

    override fun onAccessibilityEvent(event: android.view.accessibility.AccessibilityEvent?) {}

    override fun onInterrupt() {}

    companion object {
        @Volatile
        var instance: MuseAccessibilityService? = null
    }
}

object ScreenControl {
    const val OFF =
        "Screen control is off. Open Companion Settings and turn on Screen control, then try again."
    const val BLOCKED =
        "Android blocked opening that from the background. Turn on Screen control in Companion Settings and try again."

    private val filler = setOf(
        "the", "a", "an", "app", "application", "please", "open", "launch", "start",
    )

    private val aliases = mapOf(
        "settings" to listOf("com.android.settings"),
        "chrome" to listOf("com.android.chrome", "com.chrome.beta", "com.chrome.dev"),
        "camera" to listOf(
            "com.motorola.camera3",
            "com.motorola.camera5",
            "com.motorola.camera2",
            "com.android.camera2",
            "com.google.android.GoogleCamera",
        ),
        "photos" to listOf("com.google.android.apps.photos"),
        "messages" to listOf("com.google.android.apps.messaging", "com.android.mms"),
        "phone" to listOf("com.google.android.dialer", "com.android.dialer"),
        "dialer" to listOf("com.google.android.dialer", "com.android.dialer"),
        "maps" to listOf("com.google.android.apps.maps"),
        "youtube" to listOf("com.google.android.youtube"),
        "gmail" to listOf("com.google.android.gm"),
        "clock" to listOf("com.google.android.deskclock", "com.android.deskclock"),
        "calendar" to listOf("com.google.android.calendar"),
        "files" to listOf("com.google.android.apps.nbu.files", "com.android.documentsui"),
    )

    data class LaunchMatch(
        val packageName: String,
        val activity: String,
        val label: String,
        val score: Int,
    )

    fun enabled(context: Context): Boolean {
        val master = Settings.Secure.getInt(
            context.contentResolver,
            Settings.Secure.ACCESSIBILITY_ENABLED,
            0,
        ) == 1
        if (!master) return false
        val component = ComponentName(context, MuseAccessibilityService::class.java)
        val expected = listOf(component.flattenToString(), component.flattenToShortString())
        val raw = Settings.Secure.getString(
            context.contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
        ) ?: return false
        return raw.split(':').any { entry ->
            expected.any { it.equals(entry, ignoreCase = true) }
        }
    }

    fun offMessage(context: Context): String {
        if (enabled(context) && MuseAccessibilityService.instance == null) {
            return "Screen control is turning on. Try again in a moment."
        }
        return OFF
    }

    fun startExternal(activity: Activity, context: Context, intent: Intent) {
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val service = MuseAccessibilityService.instance
        try {
            when {
                service != null -> service.startActivity(intent)
                activity.hasWindowFocus() -> activity.startActivity(intent)
                else -> context.startActivity(intent)
            }
        } catch (e: ActivityNotFoundException) {
            throw e
        } catch (_: SecurityException) {
            throw IllegalStateException(blocked(context, service, activity))
        } catch (e: RuntimeException) {
            if (service == null && !activity.hasWindowFocus()) {
                throw IllegalStateException(blocked(context, service, activity))
            }
            throw e
        }
    }

    fun resolveLaunch(pm: PackageManager, query: String): LaunchMatch {
        val trimmed = query.trim()
        require(trimmed.isNotEmpty()) { "name is required" }
        if (!trimmed.contains(' ') && trimmed.contains('.')) {
            val direct = pm.getLaunchIntentForPackage(trimmed)?.component
            if (direct != null) {
                val label = try {
                    pm.getApplicationInfo(direct.packageName, 0).loadLabel(pm).toString()
                } catch (_: Exception) {
                    direct.packageName
                }
                return LaunchMatch(direct.packageName, direct.className, label, 1000)
            }
        }
        val needle = meaningful(trimmed).ifBlank { trimmed.lowercase() }
        val needleLower = needle.lowercase()
        val words = needleLower.split(' ').filter { it.length >= 2 }
        val main = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val scored = mutableListOf<LaunchMatch>()
        for (info in pm.queryIntentActivities(main, 0)) {
            val pkg = info.activityInfo.packageName
            val label = info.loadLabel(pm).toString()
            val labelLower = label.lowercase()
            val pkgLower = pkg.lowercase()
            var score = when {
                pkg.equals(trimmed, ignoreCase = true) || pkg.equals(needle, ignoreCase = true) -> 1000
                label.equals(needle, ignoreCase = true) || label.equals(trimmed, ignoreCase = true) -> 800
                needleLower.length >= 2 && labelLower.startsWith(needleLower) -> 600
                words.isNotEmpty() && words.all { word ->
                    labelLower.contains(word) || pkgLower.contains(word)
                } -> 500
                needleLower.length >= 2 && labelLower.contains(needleLower) -> 400
                needleLower.length >= 2 && pkgLower.contains(needleLower) -> 300
                else -> 0
            }
            if (aliases[needleLower].orEmpty().any { it.equals(pkg, ignoreCase = true) }) {
                score = max(score, 900)
            }
            if (score > 0) {
                scored.add(LaunchMatch(pkg, info.activityInfo.name, label, score))
            }
        }
        if (scored.isEmpty()) throw IllegalArgumentException("no app matches $trimmed")
        val best = scored.maxOf { it.score }
        val ties = scored.filter { it.score == best }.distinctBy { it.packageName }
        if (best < 500 && ties.size > 1) {
            val names = ties.take(5).joinToString(", ") { "${it.label} (${it.packageName})" }
            throw IllegalArgumentException("several apps match $trimmed: $names")
        }
        return ties.minWith(compareBy({ it.label.length }, { it.label.lowercase() }, { it.packageName }))
    }

    fun listApps(pm: PackageManager, query: String): Map<String, Any?> {
        val needle = query.trim()
        val main = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val apps = pm.queryIntentActivities(main, 0).map { info ->
            mapOf(
                "name" to info.loadLabel(pm).toString(),
                "package" to info.activityInfo.packageName,
            )
        }.sortedBy { it["name"]?.lowercase() }
        val filtered = if (needle.isEmpty()) {
            apps
        } else {
            apps.filter { app ->
                app["name"].orEmpty().contains(needle, ignoreCase = true) ||
                    app["package"].orEmpty().contains(needle, ignoreCase = true)
            }
        }
        val cap = if (needle.isEmpty()) 200 else 40
        return mapOf(
            "apps" to filtered.take(cap),
            "count" to filtered.size,
            "truncated" to (filtered.size > cap),
        )
    }

    fun displaySize(context: Context): Pair<Int, Int> {
        val wm = context.getSystemService(WindowManager::class.java) ?: return 0 to 0
        if (Build.VERSION.SDK_INT >= 30) {
            val bounds = wm.currentWindowMetrics.bounds
            return bounds.width() to bounds.height()
        }
        val metrics = android.util.DisplayMetrics()
        @Suppress("DEPRECATION")
        wm.defaultDisplay.getRealMetrics(metrics)
        return metrics.widthPixels to metrics.heightPixels
    }

    fun screenshot(
        context: Context,
        main: Handler,
        io: Handler,
        result: MethodChannel.Result,
    ) {
        val service = MuseAccessibilityService.instance
        if (service == null) {
            result.error("phone", offMessage(context), null)
            return
        }
        if (Build.VERSION.SDK_INT < 30) {
            result.error("phone", "screenshots need Android 11", null)
            return
        }
        captureScreen(service, main, io, result)
    }

    fun tap(context: Context, main: Handler, params: Map<String, Any?>, result: MethodChannel.Result) {
        val service = requireService(context)
        val text = params.string("text")
        if (text.isNotBlank()) {
            tapText(context, service, main, text, params["long"] == true, result)
            return
        }
        val size = displaySize(context)
        val point = point(params, "x", "y", "x_percent", "y_percent", size)
            ?: throw IllegalArgumentException("text, x and y, or x_percent and y_percent is required")
        val duration = if (params["long"] == true) 600L else 80L
        gesture(
            main,
            service,
            stroke(point.first, point.second, point.first + 1f, point.second, duration),
            result,
            mapOf("status" to "tapped", "x" to point.first, "y" to point.second),
        )
    }

    fun swipe(context: Context, main: Handler, params: Map<String, Any?>, result: MethodChannel.Result) {
        val service = requireService(context)
        val size = displaySize(context)
        val start = point(params, "x", "y", "x_percent", "y_percent", size)
            ?: throw IllegalArgumentException("x and y, or x_percent and y_percent, are required")
        val end = point(params, "x2", "y2", "x2_percent", "y2_percent", size)
            ?: throw IllegalArgumentException("x2 and y2, or x2_percent and y2_percent, are required")
        val duration = params.int("duration").takeIf { it > 0 }?.toLong()?.coerceIn(80L, 2000L) ?: 300L
        gesture(
            main,
            service,
            stroke(start.first, start.second, end.first, end.second, duration),
            result,
            mapOf(
                "status" to "swiped",
                "x" to start.first,
                "y" to start.second,
                "x2" to end.first,
                "y2" to end.second,
            ),
        )
    }

    fun ui(context: Context, query: String): Map<String, Any?> {
        val service = requireService(context)
        val roots = roots(service)
        if (roots.isEmpty()) throw IllegalStateException("the screen is not available yet")
        val pkg = roots.firstOrNull()?.packageName?.toString().orEmpty()
        val nodes = mutableListOf<Map<String, Any?>>()
        var visited = 0
        var truncated = false
        try {
            for (root in roots) {
                val walk = walkUi(root, query.trim(), nodes, visited)
                visited = walk.first
                truncated = truncated || walk.second
            }
        } finally {
            roots.forEach { it.recycle() }
        }
        return mapOf(
            "package" to pkg,
            "nodes" to nodes,
            "truncated" to truncated,
        )
    }

    fun type(context: Context, text: String, target: String): Map<String, Any?> {
        require(text.isNotBlank()) { "text is required" }
        require(text.length <= 8000) { "text is too long" }
        val service = requireService(context)
        val roots = roots(service)
        if (roots.isEmpty()) throw IllegalStateException("the screen is not available yet")
        try {
            val fields = mutableListOf<Field>()
            for (root in roots) collectFields(root, fields)
            val chosen = chooseField(fields, target.trim())
            val args = Bundle()
            args.putCharSequence(
                AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                text,
            )
            val ok = performOnBounds(
                roots,
                chosen.bounds,
                AccessibilityNodeInfo.ACTION_SET_TEXT,
                args,
            )
            if (!ok) throw IllegalStateException("that field did not accept text")
            return mapOf("status" to "typed", "characters" to text.length)
        } finally {
            roots.forEach { it.recycle() }
        }
    }

    fun press(context: Context, key: String): Map<String, Any?> {
        val service = requireService(context)
        val name = key.trim().lowercase()
        val action = when (name) {
            "back" -> AccessibilityService.GLOBAL_ACTION_BACK
            "home" -> AccessibilityService.GLOBAL_ACTION_HOME
            "recents", "overview" -> AccessibilityService.GLOBAL_ACTION_RECENTS
            "notifications" -> AccessibilityService.GLOBAL_ACTION_NOTIFICATIONS
            "quick_settings" -> AccessibilityService.GLOBAL_ACTION_QUICK_SETTINGS
            "lock" -> {
                if (Build.VERSION.SDK_INT < 28) {
                    throw IllegalArgumentException("lock needs Android 9")
                }
                AccessibilityService.GLOBAL_ACTION_LOCK_SCREEN
            }
            "power" -> AccessibilityService.GLOBAL_ACTION_POWER_DIALOG
            else -> throw IllegalArgumentException(
                "key must be back, home, recents, notifications, quick_settings, lock, or power",
            )
        }
        if (!service.performGlobalAction(action)) {
            throw IllegalStateException("that key was not available")
        }
        return mapOf("status" to "pressed", "key" to name)
    }

    fun screenControl(activity: Activity, context: Context, action: String): Map<String, Any?> {
        if (action == "open") {
            openSettings(activity, context)
        } else if (action.isNotEmpty() && action != "status") {
            throw IllegalArgumentException("action must be status or open")
        }
        return mapOf(
            "enabled" to enabled(context),
            "bound" to (MuseAccessibilityService.instance != null),
            "status" to if (action == "open") "opened" else "ok",
        )
    }

    private fun openSettings(activity: Activity, context: Context) {
        val component = ComponentName(context, MuseAccessibilityService::class.java)
            .flattenToString()
        val details = Intent("android.settings.ACCESSIBILITY_DETAILS_SETTINGS").apply {
            putExtra("android.intent.extra.COMPONENT_NAME", component)
        }
        try {
            startExternal(activity, context, details)
        } catch (_: ActivityNotFoundException) {
            startExternal(activity, context, Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
        }
    }

    private fun blocked(context: Context, service: MuseAccessibilityService?, activity: Activity): String {
        if (service == null && enabled(context) && !activity.hasWindowFocus()) {
            return "Screen control is turning on. Try again in a moment."
        }
        return BLOCKED
    }

    private fun requireService(context: Context): MuseAccessibilityService {
        return MuseAccessibilityService.instance ?: throw IllegalStateException(offMessage(context))
    }

    private fun meaningful(raw: String): String {
        return raw.trim().lowercase().split(Regex("\\s+"))
            .filter { it.isNotEmpty() && it !in filler }
            .joinToString(" ")
    }

    @RequiresApi(30)
    private fun captureScreen(
        service: MuseAccessibilityService,
        main: Handler,
        io: Handler,
        result: MethodChannel.Result,
    ) {
        val done = AtomicBoolean(false)
        val timeout = Runnable {
            if (done.compareAndSet(false, true)) {
                fail(result, "screenshot timed out")
            }
        }
        main.postDelayed(timeout, 8_000)
        val executor = Executor { command -> io.post(command) }
        try {
            service.takeScreenshot(
                Display.DEFAULT_DISPLAY,
                executor,
                object : AccessibilityService.TakeScreenshotCallback {
                    override fun onSuccess(screenshot: AccessibilityService.ScreenshotResult) {
                        val buffer = screenshot.hardwareBuffer
                        try {
                            val hardware = Bitmap.wrapHardwareBuffer(buffer, screenshot.colorSpace)
                                ?: throw IllegalStateException("screenshot was empty")
                            val copy = hardware.copy(Bitmap.Config.ARGB_8888, false)
                            hardware.recycle()
                            if (copy == null) throw IllegalStateException("screenshot was empty")
                            val (bytes, width, height) = jpegBytes(copy)
                            main.post {
                                if (done.compareAndSet(false, true)) {
                                    main.removeCallbacks(timeout)
                                    succeed(
                                        result,
                                        mapOf(
                                            "jpeg" to bytes,
                                            "width" to width,
                                            "height" to height,
                                            "status" to "Looking at the screen",
                                        ),
                                    )
                                }
                            }
                        } catch (e: Exception) {
                            main.post {
                                if (done.compareAndSet(false, true)) {
                                    main.removeCallbacks(timeout)
                                    fail(result, e.message ?: "screenshot failed")
                                }
                            }
                        } finally {
                            try {
                                buffer.close()
                            } catch (_: Exception) {
                            }
                        }
                    }

                    override fun onFailure(errorCode: Int) {
                        main.post {
                            if (done.compareAndSet(false, true)) {
                                main.removeCallbacks(timeout)
                                fail(result, screenshotError(errorCode))
                            }
                        }
                    }
                },
            )
        } catch (e: Exception) {
            if (done.compareAndSet(false, true)) {
                main.removeCallbacks(timeout)
                fail(result, e.message ?: "screenshot failed")
            }
        }
    }

    @RequiresApi(30)
    private fun screenshotError(code: Int): String = when (code) {
        AccessibilityService.ERROR_TAKE_SCREENSHOT_INTERVAL_TIME_SHORT -> "try again in a moment."
        AccessibilityService.ERROR_TAKE_SCREENSHOT_SECURE_WINDOW -> "that screen cannot be captured"
        AccessibilityService.ERROR_TAKE_SCREENSHOT_NO_ACCESSIBILITY_ACCESS -> OFF
        else -> "screenshot failed ($code)"
    }

    private fun jpegBytes(source: Bitmap): Triple<ByteArray, Int, Int> {
        var bitmap = scaleDown(source, 1080)
        if (bitmap !== source) source.recycle()
        var bytes = compress(bitmap, 75)
        if (bytes.size > 1_200_000) bytes = compress(bitmap, 50)
        if (bytes.size > 1_200_000) {
            val smaller = scaleDown(bitmap, 720)
            if (smaller !== bitmap) bitmap.recycle()
            bitmap = smaller
            bytes = compress(bitmap, 45)
        }
        val width = bitmap.width
        val height = bitmap.height
        bitmap.recycle()
        return Triple(bytes, width, height)
    }

    private fun scaleDown(source: Bitmap, maxEdge: Int): Bitmap {
        val longEdge = max(source.width, source.height)
        if (longEdge <= maxEdge || longEdge <= 0) return source
        val scale = maxEdge.toFloat() / longEdge
        val width = max(1, (source.width * scale).roundToInt())
        val height = max(1, (source.height * scale).roundToInt())
        return Bitmap.createScaledBitmap(source, width, height, true)
    }

    private fun compress(bitmap: Bitmap, quality: Int): ByteArray {
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, quality, out)
        return out.toByteArray()
    }

    private fun tapText(
        context: Context,
        service: MuseAccessibilityService,
        main: Handler,
        text: String,
        long: Boolean,
        result: MethodChannel.Result,
    ) {
        val roots = roots(service)
        if (roots.isEmpty()) throw IllegalStateException("the screen is not available yet")
        val best = try {
            val hits = mutableListOf<Hit>()
            for (root in roots) collectHits(root, text, hits)
            hits.minWithOrNull(
                compareBy<Hit>({ !it.clickable }, { it.bounds.width() * it.bounds.height() }),
            ) ?: throw IllegalArgumentException("nothing on screen matches $text")
        } catch (e: Exception) {
            roots.forEach { it.recycle() }
            throw e
        }
        val action = if (long) {
            AccessibilityNodeInfo.ACTION_LONG_CLICK
        } else {
            AccessibilityNodeInfo.ACTION_CLICK
        }
        val clicked = try {
            performOnBounds(roots, best.bounds, action, null)
        } finally {
            roots.forEach { it.recycle() }
        }
        val size = displaySize(context)
        val x = best.bounds.exactCenterX().coerceIn(0f, (size.first - 1).coerceAtLeast(0).toFloat())
        val y = best.bounds.exactCenterY().coerceIn(0f, (size.second - 1).coerceAtLeast(0).toFloat())
        if (clicked) {
            succeed(
                result,
                mapOf("status" to "tapped", "text" to text, "x" to x, "y" to y, "click" to true),
            )
            return
        }
        val duration = if (long) 600L else 80L
        gesture(
            main,
            service,
            stroke(x, y, x + 1f, y, duration),
            result,
            mapOf("status" to "tapped", "text" to text, "x" to x, "y" to y, "click" to false),
        )
    }

    private fun gesture(
        main: Handler,
        service: MuseAccessibilityService,
        gesture: GestureDescription,
        result: MethodChannel.Result,
        ok: Map<String, Any?>,
    ) {
        val done = AtomicBoolean(false)
        val timeout = Runnable {
            if (done.compareAndSet(false, true)) fail(result, "the gesture timed out")
        }
        val dispatched = try {
            service.dispatchGesture(
                gesture,
                object : AccessibilityService.GestureResultCallback() {
                    override fun onCompleted(gestureDescription: GestureDescription?) {
                        if (done.compareAndSet(false, true)) {
                            main.removeCallbacks(timeout)
                            succeed(result, ok)
                        }
                    }

                    override fun onCancelled(gestureDescription: GestureDescription?) {
                        if (done.compareAndSet(false, true)) {
                            main.removeCallbacks(timeout)
                            fail(result, "the gesture was cancelled")
                        }
                    }
                },
                main,
            )
        } catch (e: Exception) {
            if (done.compareAndSet(false, true)) fail(result, e.message ?: "the gesture could not start")
            return
        }
        if (!dispatched) {
            if (done.compareAndSet(false, true)) fail(result, "the gesture could not start")
            return
        }
        main.postDelayed(timeout, 4_000)
    }

    private fun stroke(x: Float, y: Float, x2: Float, y2: Float, duration: Long): GestureDescription {
        val path = Path().apply {
            moveTo(x, y)
            lineTo(x2, y2)
        }
        val stroke = GestureDescription.StrokeDescription(path, 0, duration)
        return GestureDescription.Builder().addStroke(stroke).build()
    }

    private fun roots(service: MuseAccessibilityService): List<AccessibilityNodeInfo> {
        val seen = HashSet<Int>()
        val roots = mutableListOf<AccessibilityNodeInfo>()
        service.rootInActiveWindow?.let { root ->
            if (seen.add(root.windowId)) roots.add(root)
        }
        val windows = service.windows ?: return roots
        for (window in windows) {
            if (window.type == AccessibilityWindowInfo.TYPE_ACCESSIBILITY_OVERLAY) continue
            if (!seen.add(window.id)) continue
            val root = window.root ?: continue
            roots.add(root)
        }
        return roots
    }

    private fun walkUi(
        node: AccessibilityNodeInfo,
        query: String,
        out: MutableList<Map<String, Any?>>,
        visitedIn: Int,
    ): Pair<Int, Boolean> {
        var visited = visitedIn
        if (out.size >= 60 || visited >= 800) return visited to true
        visited += 1
        val row = describe(node)
        val text = row["text"] as? String ?: ""
        val description = row["description"] as? String ?: ""
        val id = row["id"] as? String ?: ""
        val interesting = text.isNotEmpty() || description.isNotEmpty() ||
            row["clickable"] == true || row["editable"] == true || row["focused"] == true ||
            row["scrollable"] == true
        val matches = query.isEmpty() ||
            text.contains(query, ignoreCase = true) ||
            description.contains(query, ignoreCase = true) ||
            id.contains(query, ignoreCase = true)
        if (interesting && matches) out.add(row)
        var truncated = false
        for (i in 0 until node.childCount) {
            if (out.size >= 60 || visited >= 800) {
                truncated = true
                break
            }
            val child = node.getChild(i) ?: continue
            val walk = walkUi(child, query, out, visited)
            visited = walk.first
            truncated = truncated || walk.second
            child.recycle()
        }
        return visited to truncated
    }

    private fun describe(node: AccessibilityNodeInfo): Map<String, Any?> {
        val rect = Rect()
        node.getBoundsInScreen(rect)
        val shown = if (node.isPassword) "" else node.text?.toString().orEmpty().take(200)
        val description = node.contentDescription?.toString().orEmpty().take(200)
        val row = mutableMapOf<String, Any?>(
            "text" to shown,
            "bounds" to "${rect.left},${rect.top},${rect.right},${rect.bottom}",
            "clickable" to node.isClickable,
            "editable" to node.isEditable,
            "focused" to node.isFocused,
        )
        if (description.isNotEmpty() && description != shown) row["description"] = description
        if (node.isPassword) row["password"] = true
        if (node.isScrollable) row["scrollable"] = true
        val id = node.viewIdResourceName?.substringAfterLast('/')?.take(80)
        if (!id.isNullOrEmpty()) row["id"] = id
        val cls = node.className?.toString()?.substringAfterLast('.')
        if (!cls.isNullOrEmpty()) row["class"] = cls
        return row
    }

    private fun collectHits(node: AccessibilityNodeInfo, query: String, hits: MutableList<Hit>) {
        val text = node.text?.toString().orEmpty()
        val description = node.contentDescription?.toString().orEmpty()
        if ((text.isNotEmpty() && text.contains(query, ignoreCase = true)) ||
            (description.isNotEmpty() && description.contains(query, ignoreCase = true))
        ) {
            val rect = Rect()
            node.getBoundsInScreen(rect)
            if (!rect.isEmpty) hits.add(Hit(Rect(rect), node.isClickable))
        }
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            try {
                collectHits(child, query, hits)
            } finally {
                child.recycle()
            }
        }
    }

    private fun performOnBounds(
        roots: List<AccessibilityNodeInfo>,
        bounds: Rect,
        action: Int,
        args: Bundle?,
    ): Boolean {
        for (root in roots) {
            if (performOnBounds(root, bounds, action, args)) return true
        }
        return false
    }

    private fun performOnBounds(
        node: AccessibilityNodeInfo,
        bounds: Rect,
        action: Int,
        args: Bundle?,
    ): Boolean {
        val rect = Rect()
        node.getBoundsInScreen(rect)
        if (rect == bounds) {
            return if (args == null) node.performAction(action) else node.performAction(action, args)
        }
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            val hit = try {
                performOnBounds(child, bounds, action, args)
            } finally {
                child.recycle()
            }
            if (hit) return true
        }
        return false
    }

    private fun collectFields(node: AccessibilityNodeInfo, out: MutableList<Field>) {
        if (node.isEditable || node.isFocused) {
            val rect = Rect()
            node.getBoundsInScreen(rect)
            if (!rect.isEmpty) {
                val hint = if (Build.VERSION.SDK_INT >= 26) node.hintText?.toString().orEmpty() else ""
                val text = if (node.isPassword) "" else node.text?.toString().orEmpty()
                out.add(Field(Rect(rect), node.isFocused, node.isEditable, hint, text))
            }
        }
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            try {
                collectFields(child, out)
            } finally {
                child.recycle()
            }
        }
    }

    private fun chooseField(fields: List<Field>, target: String): Field {
        if (target.isNotEmpty()) {
            return fields.firstOrNull { field ->
                field.editable && (
                    field.hint.contains(target, ignoreCase = true) ||
                        field.text.contains(target, ignoreCase = true)
                    )
            } ?: throw IllegalArgumentException("no text field matches $target")
        }
        return fields.firstOrNull { it.focused && it.editable }
            ?: fields.firstOrNull { it.editable }
            ?: throw IllegalStateException("no text field is focused. Tap a field first.")
    }

    private fun point(
        params: Map<String, Any?>,
        xKey: String,
        yKey: String,
        xpKey: String,
        ypKey: String,
        size: Pair<Int, Int>,
    ): Pair<Float, Float>? {
        val xp = params.number(xpKey)
        val yp = params.number(ypKey)
        val x = params.number(xKey)
        val y = params.number(yKey)
        if (xp == null && yp == null && x == null && y == null) return null
        if (size.first <= 1 || size.second <= 1) {
            throw IllegalStateException("the screen size is not available yet")
        }
        val px = when {
            xp != null -> (xp.coerceIn(0.0, 100.0) / 100.0) * (size.first - 1)
            x != null -> x
            else -> throw IllegalArgumentException("$xKey and $yKey are both required")
        }
        val py = when {
            yp != null -> (yp.coerceIn(0.0, 100.0) / 100.0) * (size.second - 1)
            y != null -> y
            else -> throw IllegalArgumentException("$xKey and $yKey are both required")
        }
        return px.coerceIn(0.0, (size.first - 1).toDouble()).toFloat() to
            py.coerceIn(0.0, (size.second - 1).toDouble()).toFloat()
    }

    private fun succeed(result: MethodChannel.Result, payload: Map<String, Any?>) {
        try {
            result.success(payload)
        } catch (_: IllegalStateException) {
        }
    }

    private fun fail(result: MethodChannel.Result, message: String) {
        try {
            result.error("phone", message, null)
        } catch (_: IllegalStateException) {
        }
    }

    private fun Map<String, Any?>.string(key: String): String = this[key] as? String ?: ""

    private fun Map<String, Any?>.int(key: String): Int = when (val value = this[key]) {
        is Int -> value
        is Long -> value.toInt()
        is Double -> value.toInt()
        else -> 0
    }

    private fun Map<String, Any?>.number(key: String): Double? = when (val value = this[key]) {
        is Int -> value.toDouble()
        is Long -> value.toDouble()
        is Double -> value
        is Float -> value.toDouble()
        else -> null
    }

    private data class Hit(val bounds: Rect, val clickable: Boolean)
    private data class Field(
        val bounds: Rect,
        val focused: Boolean,
        val editable: Boolean,
        val hint: String,
        val text: String,
    )
}
