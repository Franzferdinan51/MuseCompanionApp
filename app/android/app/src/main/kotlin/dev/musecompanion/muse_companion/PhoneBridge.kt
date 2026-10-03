package dev.musecompanion.muse_companion

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.location.Location
import android.location.LocationManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.ImageReader
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.provider.AlarmClock
import android.provider.CalendarContract
import android.provider.ContactsContract
import android.provider.Settings
import android.speech.tts.TextToSpeech
import android.telephony.SmsManager
import android.view.KeyEvent
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/**
 * The phone side of the companion commands: camera, microphone, speech,
 * and the everyday controls a Muse can ask a phone to do.
 */
class PhoneBridge(private val activity: MainActivity) {
    private val context: Context = activity.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private val ioThread = HandlerThread("muse-phone").apply { start() }
    private val io = Handler(ioThread.looper)
    private var tts: TextToSpeech? = null
    private var recorder: AudioRecord? = null
    private var pcm: ByteArrayOutputStream? = null
    private var reader: Thread? = null
    @Volatile private var recording = false

    fun register(messenger: BinaryMessenger) {
        tts = TextToSpeech(context) { }
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "captureJpeg" -> captureJpeg(result)
                    "startRecording" -> {
                        startRecording()
                        result.success(null)
                    }
                    "stopRecording" -> result.success(stopRecording())
                    "recordWav" -> {
                        val seconds = call.argument<Int>("seconds") ?: 5
                        io.post {
                            try {
                                startRecording()
                                Thread.sleep(seconds.coerceIn(1, 20) * 1000L)
                                val wav = stopRecording()
                                main.post { result.success(wav) }
                            } catch (e: Exception) {
                                main.post { result.error("phone", e.message, null) }
                            }
                        }
                    }
                    "speak" -> {
                        speak(call.argument<String>("text") ?: "")
                        result.success(null)
                    }
                    "openNotificationAccess" -> {
                        openNotificationAccess()
                        result.success(null)
                    }
                    "run" -> {
                        val command = call.argument<String>("command") ?: ""
                        @Suppress("UNCHECKED_CAST")
                        val params = call.argument<Map<String, Any?>>("params") ?: emptyMap()
                        if (command == "phone.location") {
                            locate(result)
                        } else {
                            result.success(dispatch(command, params))
                        }
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("phone", e.message ?: e.javaClass.simpleName, null)
            }
        }
    }

    private fun captureJpeg(result: MethodChannel.Result) {
        val manager = context.getSystemService(CameraManager::class.java)
            ?: throw IllegalStateException("no camera")
        val id = backCamera(manager)
        val reader = ImageReader.newInstance(1280, 720, android.graphics.ImageFormat.JPEG, 1)
        val delivered = AtomicReference(false)
        val opened = AtomicReference<CameraDevice?>(null)
        reader.setOnImageAvailableListener({ imageReader ->
            val image = imageReader.acquireLatestImage() ?: return@setOnImageAvailableListener
            try {
                val buffer = image.planes[0].buffer
                val bytes = ByteArray(buffer.remaining())
                buffer.get(bytes)
                if (delivered.compareAndSet(false, true)) {
                    main.post { result.success(bytes) }
                }
            } finally {
                image.close()
                opened.get()?.close()
                imageReader.close()
            }
        }, io)
        manager.openCamera(id, object : CameraDevice.StateCallback() {
            override fun onOpened(camera: CameraDevice) {
                opened.set(camera)
                try {
                    camera.createCaptureSession(
                        listOf(reader.surface),
                        object : CameraCaptureSession.StateCallback() {
                            override fun onConfigured(session: CameraCaptureSession) {
                                try {
                                    val request = camera.createCaptureRequest(
                                        CameraDevice.TEMPLATE_STILL_CAPTURE
                                    )
                                    request.addTarget(reader.surface)
                                    request.set(
                                        CaptureRequest.JPEG_ORIENTATION,
                                        jpegOrientation(manager, id)
                                    )
                                    session.capture(request.build(), null, io)
                                } catch (e: Exception) {
                                    camera.close()
                                    fail(result, e.message ?: "camera failed")
                                }
                            }

                            override fun onConfigureFailed(session: CameraCaptureSession) {
                                camera.close()
                                fail(result, "camera session failed")
                            }
                        },
                        io
                    )
                } catch (e: Exception) {
                    camera.close()
                    fail(result, e.message ?: "camera failed")
                }
            }

            override fun onDisconnected(camera: CameraDevice) {
                camera.close()
            }

            override fun onError(camera: CameraDevice, error: Int) {
                camera.close()
                fail(result, "camera error $error")
            }
        }, io)
    }

    private fun backCamera(manager: CameraManager): String {
        for (id in manager.cameraIdList) {
            val facing = manager.getCameraCharacteristics(id)
                .get(CameraCharacteristics.LENS_FACING)
            if (facing == CameraCharacteristics.LENS_FACING_BACK) return id
        }
        return manager.cameraIdList.firstOrNull()
            ?: throw IllegalStateException("this phone has no camera")
    }

    private fun jpegOrientation(manager: CameraManager, id: String): Int {
        val sensor = manager.getCameraCharacteristics(id)
            .get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90
        val rotation = activity.display?.rotation ?: 0
        val device = when (rotation) {
            1 -> 90
            2 -> 180
            3 -> 270
            else -> 0
        }
        return (sensor - device + 360) % 360
    }

    private fun startRecording() {
        if (recording) return
        val rate = 16000
        val min = AudioRecord.getMinBufferSize(
            rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT
        )
        if (min <= 0) throw IllegalStateException("microphone is unavailable")
        val record = AudioRecord(
            MediaRecorder.AudioSource.MIC,
            rate,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            min * 2,
        )
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            throw IllegalStateException("microphone did not start")
        }
        val out = ByteArrayOutputStream()
        recorder = record
        pcm = out
        recording = true
        record.startRecording()
        val thread = Thread {
            val buf = ByteArray(min)
            while (recording) {
                val n = record.read(buf, 0, buf.size)
                if (n > 0) synchronized(out) { out.write(buf, 0, n) }
            }
        }
        reader = thread
        thread.start()
    }

    private fun stopRecording(): ByteArray {
        recording = false
        try {
            reader?.join(800)
        } catch (_: InterruptedException) {
        }
        reader = null
        val record = recorder
        recorder = null
        try {
            record?.stop()
        } catch (_: Exception) {
        }
        record?.release()
        val samples = pcm?.let { synchronized(it) { it.toByteArray() } } ?: ByteArray(0)
        pcm = null
        if (samples.isEmpty()) throw IllegalStateException("didn't catch that")
        return wav(samples, 16000)
    }

    private fun wav(pcm: ByteArray, rate: Int): ByteArray {
        val header = ByteArray(44)
        header[0] = 'R'.code.toByte(); header[1] = 'I'.code.toByte()
        header[2] = 'F'.code.toByte(); header[3] = 'F'.code.toByte()
        writeLe(header, 4, 36 + pcm.size, 4)
        "WAVE".toByteArray().copyInto(header, 8)
        "fmt ".toByteArray().copyInto(header, 12)
        writeLe(header, 16, 16, 4)
        writeLe(header, 20, 1, 2)
        writeLe(header, 22, 1, 2)
        writeLe(header, 24, rate, 4)
        writeLe(header, 28, rate * 2, 4)
        writeLe(header, 32, 2, 2)
        writeLe(header, 34, 16, 2)
        "data".toByteArray().copyInto(header, 36)
        writeLe(header, 40, pcm.size, 4)
        return header + pcm
    }

    private fun writeLe(dest: ByteArray, offset: Int, value: Int, bytes: Int) {
        var v = value
        for (i in 0 until bytes) {
            dest[offset + i] = (v and 0xFF).toByte()
            v = v shr 8
        }
    }

    private fun speak(text: String) {
        val engine = tts ?: return
        engine.language = Locale.getDefault()
        engine.setAudioAttributes(
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build()
        )
        engine.speak(text, TextToSpeech.QUEUE_FLUSH, null, "muse-reply")
    }

    private fun dispatch(command: String, params: Map<String, Any?>): Map<String, Any?> {
        return when (command) {
            "phone.open_url" -> openUrl(params.string("url"))
            "phone.launch_app" -> launchApp(params.string("name"))
            "phone.list_apps" -> mapOf("apps" to listApps())
            "phone.clipboard" -> clipboard(params.string("action"), params.string("text"))
            "phone.flashlight" -> flashlight(params["on"] == true)
            "phone.volume" -> volume(params.int("level"))
            "phone.brightness" -> brightness(params.int("level"))
            "phone.notify" -> notify(params.string("title"), params.string("text"))
            "phone.alarm" -> alarm(params.int("hour"), params.int("minute"), params.string("message"))
            "phone.dial" -> dial(params.string("number"), place = false)
            "phone.call" -> dial(params.string("number"), place = true)
            "phone.sms" -> sms(params.string("number"), params.string("text"), params["send"] == true)
            "phone.messages" -> mapOf("messages" to inbox())
            "phone.notifications" -> mapOf(
                "enabled" to MuseNotificationListener.enabled(),
                "notifications" to MuseNotificationListener.recent(),
            )
            "phone.contacts" -> mapOf("contacts" to contacts(params.string("query")))
            "phone.events" -> mapOf("events" to events())
            "phone.share" -> share(params.string("text"))
            "phone.speak" -> {
                speak(params.string("text"))
                mapOf("status" to "speaking")
            }
            "phone.media" -> media(params.string("action"))
            "phone.capabilities" -> capabilities()
            else -> throw IllegalArgumentException("unsupported command: $command")
        }
    }

    private fun openUrl(url: String): Map<String, Any?> {
        require(url.startsWith("http://") || url.startsWith("https://")) { "url must be http(s)" }
        val intent = Intent(Intent.ACTION_VIEW, android.net.Uri.parse(url))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
        return mapOf("status" to "opened", "url" to url)
    }

    private fun launchApp(name: String): Map<String, Any?> {
        require(name.isNotBlank()) { "name is required" }
        val pm = context.packageManager
        val direct = pm.getLaunchIntentForPackage(name)
        val intent = direct ?: run {
            val main = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
            val match = pm.queryIntentActivities(main, 0).firstOrNull { info ->
                val label = info.loadLabel(pm).toString()
                label.contains(name, ignoreCase = true) ||
                    info.activityInfo.packageName.contains(name, ignoreCase = true)
            } ?: throw IllegalArgumentException("no app matches $name")
            Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
                .setClassName(match.activityInfo.packageName, match.activityInfo.name)
        }
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
        return mapOf("status" to "launched", "name" to name)
    }

    private fun listApps(): List<Map<String, String>> {
        val pm = context.packageManager
        val main = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        return pm.queryIntentActivities(main, 0).map { info ->
            mapOf(
                "name" to info.loadLabel(pm).toString(),
                "package" to info.activityInfo.packageName,
            )
        }.sortedBy { it["name"] }.take(80)
    }

    private fun clipboard(action: String, text: String): Map<String, Any?> {
        val clipboard = context.getSystemService(ClipboardManager::class.java)
            ?: throw IllegalStateException("no clipboard")
        return when (action) {
            "set" -> {
                clipboard.setPrimaryClip(ClipData.newPlainText("muse", text))
                mapOf("status" to "set", "characters" to text.length)
            }
            else -> {
                val clip = clipboard.primaryClip
                val value = if (clip != null && clip.itemCount > 0) {
                    clip.getItemAt(0).coerceToText(context)?.toString() ?: ""
                } else ""
                mapOf("status" to "ok", "text" to value)
            }
        }
    }

    private fun flashlight(on: Boolean): Map<String, Any?> {
        val manager = context.getSystemService(CameraManager::class.java)
            ?: throw IllegalStateException("no camera")
        val id = manager.cameraIdList.firstOrNull()
            ?: throw IllegalStateException("no flashlight")
        manager.setTorchMode(id, on)
        return mapOf("on" to on)
    }

    private fun volume(level: Int): Map<String, Any?> {
        val audio = context.getSystemService(AudioManager::class.java)
            ?: throw IllegalStateException("no audio")
        val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        val scaled = (level.coerceIn(0, 100) / 100.0 * max).toInt()
        audio.setStreamVolume(AudioManager.STREAM_MUSIC, scaled, 0)
        return mapOf("level" to level.coerceIn(0, 100))
    }

    private fun brightness(level: Int): Map<String, Any?> {
        if (!Settings.System.canWrite(context)) {
            val intent = Intent(Settings.ACTION_MANAGE_WRITE_SETTINGS).apply {
                data = android.net.Uri.parse("package:${context.packageName}")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(intent)
            throw IllegalStateException(
                "allow Muse Companion to modify system settings, then set brightness again"
            )
        }
        val value = (level.coerceIn(0, 100) / 100.0 * 255).toInt()
        Settings.System.putInt(context.contentResolver, Settings.System.SCREEN_BRIGHTNESS, value)
        return mapOf("level" to level.coerceIn(0, 100))
    }

    private fun notify(title: String, text: String): Map<String, Any?> {
        val manager = context.getSystemService(NotificationManager::class.java)
            ?: throw IllegalStateException("no notifications")
        val channelId = "muse_companion_alerts"
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(
                NotificationChannel(channelId, "Muse", NotificationManager.IMPORTANCE_DEFAULT)
            )
        }
        val launch = PendingIntent.getActivity(
            context, 0,
            Intent(context, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle(title.ifBlank { "Muse" })
            .setContentText(text)
            .setContentIntent(launch)
            .setAutoCancel(true)
            .build()
        manager.notify((System.currentTimeMillis() % Int.MAX_VALUE).toInt(), notification)
        return mapOf("status" to "posted")
    }

    private fun alarm(hour: Int, minute: Int, message: String): Map<String, Any?> {
        val intent = Intent(AlarmClock.ACTION_SET_ALARM).apply {
            putExtra(AlarmClock.EXTRA_HOUR, hour.coerceIn(0, 23))
            putExtra(AlarmClock.EXTRA_MINUTES, minute.coerceIn(0, 59))
            putExtra(AlarmClock.EXTRA_MESSAGE, message.ifBlank { "Muse" })
            putExtra(AlarmClock.EXTRA_SKIP_UI, true)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        context.startActivity(intent)
        return mapOf("status" to "set", "hour" to hour, "minute" to minute)
    }

    private fun dial(number: String, place: Boolean): Map<String, Any?> {
        require(number.isNotBlank()) { "number is required" }
        val action = if (place) Intent.ACTION_CALL else Intent.ACTION_DIAL
        val intent = Intent(action, android.net.Uri.parse("tel:$number"))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
        return mapOf("status" to if (place) "calling" else "dialer", "number" to number)
    }

    private fun sms(number: String, text: String, send: Boolean): Map<String, Any?> {
        require(number.isNotBlank()) { "number is required" }
        if (!send) {
            val intent = Intent(Intent.ACTION_SENDTO, android.net.Uri.parse("smsto:$number")).apply {
                putExtra("sms_body", text)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(intent)
            return mapOf("status" to "composer", "sent" to false)
        }
        val sms = if (Build.VERSION.SDK_INT >= 31) {
            context.getSystemService(SmsManager::class.java)
                ?: throw IllegalStateException("SMS is not available")
        } else {
            @Suppress("DEPRECATION")
            SmsManager.getDefault()
        }
        sms.sendTextMessage(number, null, text, null, null)
        return mapOf("status" to "sent", "sent" to true)
    }

    private fun inbox(): List<Map<String, Any?>> {
        val cursor = context.contentResolver.query(
            android.provider.Telephony.Sms.Inbox.CONTENT_URI,
            arrayOf(
                android.provider.Telephony.Sms.ADDRESS,
                android.provider.Telephony.Sms.BODY,
                android.provider.Telephony.Sms.DATE,
            ),
            null, null,
            "${android.provider.Telephony.Sms.DATE} DESC LIMIT 12",
        ) ?: return emptyList()
        cursor.use {
            val rows = mutableListOf<Map<String, Any?>>()
            while (it.moveToNext() && rows.size < 12) {
                rows.add(
                    mapOf(
                        "from" to it.getString(0),
                        "body" to it.getString(1),
                        "when" to it.getLong(2),
                    )
                )
            }
            return rows
        }
    }

    private fun contacts(query: String): List<Map<String, String>> {
        val uri = ContactsContract.CommonDataKinds.Phone.CONTENT_URI
        val cursor = context.contentResolver.query(
            uri,
            arrayOf(
                ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
                ContactsContract.CommonDataKinds.Phone.NUMBER,
            ),
            "${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} LIKE ? OR " +
                "${ContactsContract.CommonDataKinds.Phone.NUMBER} LIKE ?",
            arrayOf("%$query%", "%$query%"),
            null,
        ) ?: return emptyList()
        cursor.use {
            val rows = mutableListOf<Map<String, String>>()
            while (it.moveToNext() && rows.size < 20) {
                rows.add(mapOf("name" to (it.getString(0) ?: ""), "number" to (it.getString(1) ?: "")))
            }
            return rows
        }
    }

    private fun events(): List<Map<String, Any?>> {
        val now = System.currentTimeMillis()
        val cursor = context.contentResolver.query(
            CalendarContract.Events.CONTENT_URI,
            arrayOf(
                CalendarContract.Events.TITLE,
                CalendarContract.Events.DTSTART,
                CalendarContract.Events.EVENT_LOCATION,
            ),
            "${CalendarContract.Events.DTSTART} >= ?",
            arrayOf(now.toString()),
            "${CalendarContract.Events.DTSTART} ASC LIMIT 15",
        ) ?: return emptyList()
        cursor.use {
            val rows = mutableListOf<Map<String, Any?>>()
            while (it.moveToNext() && rows.size < 15) {
                rows.add(
                    mapOf(
                        "title" to it.getString(0),
                        "start" to it.getLong(1),
                        "location" to it.getString(2),
                    )
                )
            }
            return rows
        }
    }

    private fun share(text: String): Map<String, Any?> {
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_TEXT, text)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        context.startActivity(Intent.createChooser(intent, "Share").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        return mapOf("status" to "sharing")
    }

    private fun media(action: String): Map<String, Any?> {
        val code = when (action) {
            "play" -> KeyEvent.KEYCODE_MEDIA_PLAY
            "pause" -> KeyEvent.KEYCODE_MEDIA_PAUSE
            "play_pause" -> KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE
            "next" -> KeyEvent.KEYCODE_MEDIA_NEXT
            "previous" -> KeyEvent.KEYCODE_MEDIA_PREVIOUS
            "stop" -> KeyEvent.KEYCODE_MEDIA_STOP
            else -> throw IllegalArgumentException("action must be play, pause, play_pause, next, previous, or stop")
        }
        val audio = context.getSystemService(AudioManager::class.java)
            ?: throw IllegalStateException("no audio")
        audio.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, code))
        audio.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_UP, code))
        return mapOf("action" to action)
    }

    private fun locate(result: MethodChannel.Result) {
        val manager = context.getSystemService(LocationManager::class.java)
            ?: throw IllegalStateException("no location")
        val fine = ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION)
        val coarse = ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION)
        if (fine != PackageManager.PERMISSION_GRANTED && coarse != PackageManager.PERMISSION_GRANTED) {
            result.error("permission", "Location permission is not granted", null)
            return
        }
        val last = listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)
            .mapNotNull { provider ->
                try {
                    manager.getLastKnownLocation(provider)
                } catch (_: Exception) {
                    null
                }
            }
            .maxByOrNull { it.time }
        if (last != null) {
            result.success(locationMap(last))
            return
        }
        io.post {
            val found = AtomicReference<Location?>(null)
            val latch = CountDownLatch(1)
            val listener = android.location.LocationListener { location ->
                found.set(location)
                latch.countDown()
            }
            try {
                val provider = if (manager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)) {
                    LocationManager.NETWORK_PROVIDER
                } else {
                    LocationManager.GPS_PROVIDER
                }
                manager.requestLocationUpdates(provider, 0L, 0f, listener, io.looper)
                latch.await(8, TimeUnit.SECONDS)
            } catch (e: Exception) {
                main.post { result.error("phone", e.message, null) }
                return@post
            } finally {
                manager.removeUpdates(listener)
            }
            val location = found.get()
            main.post {
                if (location == null) result.error("phone", "location is not available yet", null)
                else result.success(locationMap(location))
            }
        }
    }

    private fun locationMap(location: Location): Map<String, Any?> = mapOf(
        "latitude" to location.latitude,
        "longitude" to location.longitude,
        "accuracy_m" to location.accuracy.toDouble(),
        "time" to location.time,
    )

    private fun capabilities(): Map<String, Any?> {
        fun granted(permission: String) =
            ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED
        return mapOf(
            "camera" to granted(Manifest.permission.CAMERA),
            "microphone" to granted(Manifest.permission.RECORD_AUDIO),
            "location" to granted(Manifest.permission.ACCESS_FINE_LOCATION),
            "sms" to granted(Manifest.permission.READ_SMS),
            "phone" to granted(Manifest.permission.CALL_PHONE),
            "contacts" to granted(Manifest.permission.READ_CONTACTS),
            "calendar" to granted(Manifest.permission.READ_CALENDAR),
            "notifications" to MuseNotificationListener.enabled(),
            "flashlight" to context.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_FLASH),
            "model" to Build.MODEL,
        )
    }

    private fun openNotificationAccess() {
        val intent = Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
    }

    private fun fail(result: MethodChannel.Result, message: String) {
        val reply = {
            try {
                result.error("phone", message, null)
            } catch (_: IllegalStateException) {
                // The camera callback can fail after a frame was already delivered.
            }
        }
        if (main.looper.isCurrentThread) reply() else main.post(reply)
    }

    private fun Map<String, Any?>.string(key: String): String = this[key] as? String ?: ""

    private fun Map<String, Any?>.int(key: String): Int = when (val value = this[key]) {
        is Int -> value
        is Long -> value.toInt()
        is Double -> value.toInt()
        else -> 0
    }

    companion object {
        const val CHANNEL = "dev.musecompanion/phone"
    }
}
