package dev.musecompanion.muse_companion

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.bluetooth.BluetoothManager
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageFormat
import android.graphics.Matrix
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureFailure
import android.hardware.camera2.CaptureRequest
import android.location.Location
import android.location.LocationManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.ExifInterface
import android.media.ImageReader
import android.media.MediaRecorder
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import android.nfc.NfcAdapter
import android.os.BatteryManager
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.PowerManager
import android.os.StatFs
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.AlarmClock
import android.provider.CalendarContract
import android.provider.ContactsContract
import android.provider.Settings
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.speech.tts.Voice
import android.telephony.SmsManager
import android.util.Size
import android.view.KeyEvent
import android.view.Surface
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.max
import kotlin.math.min

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
    private val capturing = AtomicBoolean(false)
    private val speakLock = Any()
    private var speakGeneration = 0
    private var pendingSpeak: MethodChannel.Result? = null
    private var ttsReady = false
    private var ttsFellBack = false
    private var enginePackage = ""
    @Volatile private var requestedVoice = ""
    private val voiceQueries = mutableListOf<MethodChannel.Result>()
    private var queuedSpeak: String? = null
    private var queuedAwait: String? = null
    private var queuedAwaitGeneration = 0

    fun register(messenger: BinaryMessenger) {
        startTts()
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "captureJpeg" -> captureJpeg(result, call.argument<String>("facing") ?: "back")
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
                    "speak" -> speakAwait(call.argument<String>("text") ?: "", result)
                    "setSpeechVoice" -> {
                        requestedVoice = sanitizeVoice(call.argument<String>("name") ?: "")
                        val engine = tts
                        if (ttsReady && engine != null) prepareEngine(engine)
                        result.success(null)
                    }
                    "listVoices" -> listVoices(result)
                    "openTtsSettings" -> {
                        openTtsSettings()
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

    private fun captureJpeg(result: MethodChannel.Result, facing: String) {
        if (Looper.myLooper() != io.looper) {
            io.post { captureJpeg(result, facing) }
            return
        }
        if (!capturing.compareAndSet(false, true)) {
            fail(result, "camera is busy")
            return
        }
        val delivered = AtomicBoolean(false)
        val cameraRef = AtomicReference<CameraDevice?>(null)
        val sessionRef = AtomicReference<CameraCaptureSession?>(null)
        var stillReader: ImageReader? = null
        var previewReader: ImageReader? = null
        val timeout = Runnable { finishCapture(result, delivered, cameraRef, sessionRef, stillReader, previewReader, "camera timed out", null) }
        fun finish(error: String?, bytes: ByteArray?) {
            io.removeCallbacks(timeout)
            finishCapture(result, delivered, cameraRef, sessionRef, stillReader, previewReader, error, bytes)
        }
        try {
            if (!awaitVisible()) {
                throw IllegalStateException(
                    "open Muse Companion so the camera can take a photo"
                )
            }
            val manager = context.getSystemService(CameraManager::class.java)
                ?: throw IllegalStateException("no camera")
            val id = cameraId(manager, facing)
            val characteristics = manager.getCameraCharacteristics(id)
            val map = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
                ?: throw IllegalStateException("camera has no capture sizes")
            val jpegSize = chooseJpegSize(map.getOutputSizes(ImageFormat.JPEG))
                ?: throw IllegalStateException("camera has no JPEG size")
            val reader = ImageReader.newInstance(jpegSize.width, jpegSize.height, ImageFormat.JPEG, 2)
            stillReader = reader
            val previewSize = map.getOutputSizes(ImageFormat.YUV_420_888)
                ?.minByOrNull { it.width.toLong() * it.height }
            if (previewSize != null) {
                previewReader = ImageReader.newInstance(
                    previewSize.width, previewSize.height, ImageFormat.YUV_420_888, 2
                )
                previewReader?.setOnImageAvailableListener({ source ->
                    source.acquireLatestImage()?.close()
                }, io)
            }
            reader.setOnImageAvailableListener({ imageReader ->
                val image = imageReader.acquireLatestImage() ?: return@setOnImageAvailableListener
                val bytes = try {
                    val buffer = image.planes[0].buffer
                    ByteArray(buffer.remaining()).also { buffer.get(it) }
                } finally {
                    image.close()
                }
                if (bytes.isEmpty()) {
                    io.post { finish("the camera returned nothing", null) }
                } else {
                    io.post { finish(null, shrinkJpeg(bytes)) }
                }
            }, io)
            io.postDelayed(timeout, 8_000)
            manager.openCamera(id, object : CameraDevice.StateCallback() {
                override fun onOpened(camera: CameraDevice) {
                    cameraRef.set(camera)
                    val targets = listOfNotNull(previewReader?.surface, reader.surface)
                    openStillSession(camera, characteristics, targets, sessionRef, ::finish)
                }

                override fun onDisconnected(camera: CameraDevice) {
                    finish("camera disconnected", null)
                }

                override fun onError(camera: CameraDevice, error: Int) {
                    finish("camera error $error", null)
                }
            }, io)
        } catch (e: SecurityException) {
            finish("camera permission is not granted", null)
        } catch (e: Exception) {
            finish(e.message ?: "camera failed", null)
        }
    }

    private fun openStillSession(
        camera: CameraDevice,
        characteristics: CameraCharacteristics,
        targets: List<Surface>,
        sessionRef: AtomicReference<CameraCaptureSession?>,
        finish: (String?, ByteArray?) -> Unit,
    ) {
        try {
            camera.createCaptureSession(targets, object : CameraCaptureSession.StateCallback() {
                override fun onConfigured(session: CameraCaptureSession) {
                    sessionRef.set(session)
                    try {
                        val preview = targets.firstOrNull { it != targets.last() }
                        if (preview != null) {
                            val previewRequest = camera.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW)
                            previewRequest.addTarget(preview)
                            applyAuto(previewRequest, characteristics)
                            session.setRepeatingRequest(previewRequest.build(), null, io)
                        }
                        val settleMs = if (preview != null) 600L else 0L
                        io.postDelayed({
                            try {
                                val still = camera.createCaptureRequest(CameraDevice.TEMPLATE_STILL_CAPTURE)
                                for (target in targets) still.addTarget(target)
                                still.set(CaptureRequest.JPEG_ORIENTATION, jpegOrientation(characteristics))
                                still.set(CaptureRequest.JPEG_QUALITY, 85.toByte())
                                applyAuto(still, characteristics)
                                session.capture(still.build(), object : CameraCaptureSession.CaptureCallback() {
                                    override fun onCaptureFailed(
                                        session: CameraCaptureSession,
                                        request: CaptureRequest,
                                        failure: CaptureFailure,
                                    ) {
                                        finish("camera capture failed", null)
                                    }
                                }, io)
                            } catch (e: Exception) {
                                finish(e.message ?: "camera failed", null)
                            }
                        }, settleMs)
                    } catch (e: Exception) {
                        finish(e.message ?: "camera failed", null)
                    }
                }

                override fun onConfigureFailed(session: CameraCaptureSession) {
                    if (targets.size > 1) {
                        openStillSession(camera, characteristics, listOf(targets.last()), sessionRef, finish)
                    } else {
                        finish("camera session failed", null)
                    }
                }
            }, io)
        } catch (e: Exception) {
            finish(e.message ?: "camera failed", null)
        }
    }

    private fun finishCapture(
        result: MethodChannel.Result,
        delivered: AtomicBoolean,
        cameraRef: AtomicReference<CameraDevice?>,
        sessionRef: AtomicReference<CameraCaptureSession?>,
        stillReader: ImageReader?,
        previewReader: ImageReader?,
        error: String?,
        bytes: ByteArray?,
    ) {
        if (!delivered.compareAndSet(false, true)) return
        capturing.set(false)
        try {
            sessionRef.get()?.stopRepeating()
        } catch (_: Exception) {
        }
        try {
            sessionRef.get()?.close()
        } catch (_: Exception) {
        }
        try {
            cameraRef.get()?.close()
        } catch (_: Exception) {
        }
        try {
            stillReader?.close()
        } catch (_: Exception) {
        }
        try {
            previewReader?.close()
        } catch (_: Exception) {
        }
        if (error != null) {
            fail(result, error)
        } else {
            val payload = bytes ?: ByteArray(0)
            val reply = {
                try {
                    result.success(payload)
                } catch (_: IllegalStateException) {
                }
            }
            if (main.looper.isCurrentThread) reply() else main.post(reply)
        }
    }

    private fun awaitVisible(): Boolean {
        if (activity.hasWindowFocus()) return true
        val launched = CountDownLatch(1)
        main.post {
            try {
                context.startActivity(
                    Intent(context, MainActivity::class.java).addFlags(
                        Intent.FLAG_ACTIVITY_NEW_TASK or
                            Intent.FLAG_ACTIVITY_SINGLE_TOP or
                            Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
                    )
                )
                if (Build.VERSION.SDK_INT >= 27) activity.setTurnScreenOn(true)
            } catch (_: Exception) {
            } finally {
                launched.countDown()
            }
        }
        launched.await(1, TimeUnit.SECONDS)
        val deadline = System.currentTimeMillis() + 1200
        while (System.currentTimeMillis() < deadline) {
            if (activity.hasWindowFocus()) return true
            try {
                Thread.sleep(40)
            } catch (_: InterruptedException) {
                return activity.hasWindowFocus()
            }
        }
        return activity.hasWindowFocus()
    }

    private fun cameraId(manager: CameraManager, facing: String): String {
        val want = when (facing) {
            "front" -> CameraCharacteristics.LENS_FACING_FRONT
            "back" -> CameraCharacteristics.LENS_FACING_BACK
            else -> throw IllegalArgumentException("facing must be back or front")
        }
        for (id in manager.cameraIdList) {
            val lens = manager.getCameraCharacteristics(id).get(CameraCharacteristics.LENS_FACING)
            if (lens == want) return id
        }
        if (facing == "back") {
            return manager.cameraIdList.firstOrNull()
                ?: throw IllegalStateException("this phone has no camera")
        }
        throw IllegalStateException("this phone has no front camera")
    }

    private fun chooseJpegSize(sizes: Array<Size>?): Size? {
        if (sizes.isNullOrEmpty()) return null
        val cap = 1280 * 720
        val under = sizes.filter { it.width >= 320 && it.height >= 240 && it.width * it.height <= cap }
        if (under.isNotEmpty()) return under.maxBy { it.width.toLong() * it.height }
        return sizes.minBy { it.width.toLong() * it.height }
    }

    private fun applyAuto(request: CaptureRequest.Builder, characteristics: CameraCharacteristics) {
        request.set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)
        request.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
        request.set(CaptureRequest.CONTROL_AWB_MODE, CaptureRequest.CONTROL_AWB_MODE_AUTO)
        val modes = characteristics.get(CameraCharacteristics.CONTROL_AF_AVAILABLE_MODES) ?: IntArray(0)
        val focus = when {
            modes.contains(CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE) ->
                CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE
            modes.contains(CaptureRequest.CONTROL_AF_MODE_AUTO) ->
                CaptureRequest.CONTROL_AF_MODE_AUTO
            else -> CaptureRequest.CONTROL_AF_MODE_OFF
        }
        request.set(CaptureRequest.CONTROL_AF_MODE, focus)
    }

    private fun jpegOrientation(characteristics: CameraCharacteristics): Int {
        val sensor = characteristics.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90
        val device = when (activity.display?.rotation ?: Surface.ROTATION_0) {
            Surface.ROTATION_90 -> 90
            Surface.ROTATION_180 -> 180
            Surface.ROTATION_270 -> 270
            else -> 0
        }
        val front = characteristics.get(CameraCharacteristics.LENS_FACING) ==
            CameraCharacteristics.LENS_FACING_FRONT
        return if (front) (sensor + device) % 360 else (sensor - device + 360) % 360
    }

    private fun shrinkJpeg(bytes: ByteArray): ByteArray {
        if (bytes.size <= 1_500_000) return bytes
        val decoded = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return bytes
        val oriented = rotateByExif(bytes, decoded)
        val longEdge = max(oriented.width, oriented.height).coerceAtLeast(1)
        val scale = min(1f, 1280f / longEdge)
        val scaled = if (scale < 1f) {
            Bitmap.createScaledBitmap(
                oriented,
                (oriented.width * scale).toInt().coerceAtLeast(1),
                (oriented.height * scale).toInt().coerceAtLeast(1),
                true,
            )
        } else {
            oriented
        }
        val out = ByteArrayOutputStream()
        scaled.compress(Bitmap.CompressFormat.JPEG, 80, out)
        if (scaled !== oriented) scaled.recycle()
        if (oriented !== decoded) oriented.recycle()
        decoded.recycle()
        val smaller = out.toByteArray()
        return if (smaller.isEmpty()) bytes else smaller
    }

    private fun rotateByExif(bytes: ByteArray, bitmap: Bitmap): Bitmap {
        val rotation = try {
            val exif = ExifInterface(ByteArrayInputStream(bytes))
            when (exif.getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)) {
                ExifInterface.ORIENTATION_ROTATE_90 -> 90f
                ExifInterface.ORIENTATION_ROTATE_180 -> 180f
                ExifInterface.ORIENTATION_ROTATE_270 -> 270f
                else -> 0f
            }
        } catch (_: Exception) {
            0f
        }
        if (rotation == 0f) return bitmap
        val matrix = Matrix().apply { postRotate(rotation) }
        return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
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
        if (text.isBlank()) return
        val engine = tts
        if (engine == null || !ttsReady) {
            queuedSpeak = text
            return
        }
        prepareEngine(engine)
        utter(engine, text)
    }

    /// Completes [result] when the utterance finishes, errors, or times out.
    /// A newer speak completes the previous result so Flutter does not hang.
    /// The callback is posted to the main thread; the main thread is never blocked.
    private fun speakAwait(text: String, result: MethodChannel.Result) {
        finishPendingSpeak()
        if (text.isBlank()) {
            result.success(null)
            return
        }
        val generation = ++speakGeneration
        synchronized(speakLock) { pendingSpeak = result }
        val timeout = (text.length * 80L).coerceIn(4000L, 60000L)
        main.postDelayed({
            if (generation == speakGeneration) finishPendingSpeak()
        }, timeout)
        val engine = tts
        if (engine == null || !ttsReady) {
            queuedSpeak = null
            queuedAwait = text
            queuedAwaitGeneration = generation
            return
        }
        engine.setOnUtteranceProgressListener(utteranceListener(generation))
        prepareEngine(engine)
        if (utter(engine, text) == TextToSpeech.ERROR) finishPendingSpeak()
    }

    private fun startTts() {
        val listener = object : TextToSpeech.OnInitListener {
            override fun onInit(status: Int) {
                if (status != TextToSpeech.SUCCESS && enginePackage == GOOGLE_TTS && !ttsFellBack) {
                    ttsFellBack = true
                    tts?.shutdown()
                    enginePackage = ""
                    tts = TextToSpeech(context, this)
                    return
                }
                ttsReady = status == TextToSpeech.SUCCESS
                val engine = tts
                if (ttsReady && engine != null) {
                    enginePackage = engine.defaultEngine ?: enginePackage
                    prepareEngine(engine)
                    val awaitText = queuedAwait
                    val generation = queuedAwaitGeneration
                    queuedAwait = null
                    if (awaitText != null && generation == speakGeneration) {
                        queuedSpeak = null
                        engine.setOnUtteranceProgressListener(utteranceListener(generation))
                        if (utter(engine, awaitText) == TextToSpeech.ERROR) finishPendingSpeak()
                    } else {
                        val fire = queuedSpeak
                        queuedSpeak = null
                        if (!fire.isNullOrBlank()) utter(engine, fire)
                    }
                } else {
                    queuedAwait = null
                    queuedSpeak = null
                    finishPendingSpeak()
                }
                val waiting = voiceQueries.toList()
                voiceQueries.clear()
                for (pending in waiting) {
                    try {
                        if (ttsReady) pending.success(voicePayload())
                        else pending.success(mapOf("engine" to "", "voices" to emptyList<Any>()))
                    } catch (_: IllegalStateException) {
                        // The Flutter side already timed out.
                    }
                }
            }
        }
        val google = googleTtsInstalled()
        enginePackage = if (google) GOOGLE_TTS else ""
        tts = if (google) TextToSpeech(context, listener, GOOGLE_TTS) else TextToSpeech(context, listener)
    }

    private fun googleTtsInstalled(): Boolean {
        val intent = Intent(TextToSpeech.Engine.INTENT_ACTION_TTS_SERVICE)
        return context.packageManager.queryIntentServices(intent, 0).any { info ->
            info.serviceInfo?.packageName == GOOGLE_TTS
        }
    }

    private fun listVoices(result: MethodChannel.Result) {
        if (!ttsReady || tts == null) {
            voiceQueries.add(result)
            return
        }
        try {
            result.success(voicePayload())
        } catch (e: Exception) {
            result.error("phone", e.message ?: "voices unavailable", null)
        }
    }

    private fun voicePayload(): Map<String, Any?> {
        val engine = tts
        val target = Locale.getDefault()
        val voices = engine?.voices?.filter { usable(it) } ?: emptyList()
        val sorted = voices.sortedWith(
            compareByDescending<Voice> { sameLanguage(it, target) }
                .thenByDescending { voiceScore(it, target, online()) }
                .thenBy { it.latency }
                .thenBy { it.name }
        )
        val same = sorted.filter { sameLanguage(it, target) }
        val others = sorted.filter { !sameLanguage(it, target) }.take(40)
        val listed = (same + others).toMutableList()
        val requested = requestedVoice
        if (requested.isNotEmpty() && listed.none { it.name == requested }) {
            voices.firstOrNull { it.name == requested }?.let { listed.add(it) }
        }
        return mapOf(
            "engine" to (engine?.defaultEngine ?: enginePackage),
            "voices" to listed.map { voiceMap(it, target) },
        )
    }

    private fun voiceMap(voice: Voice, target: Locale): Map<String, Any?> {
        val language = voice.locale.displayLanguage.ifBlank { voice.locale.language }
        return mapOf(
            "name" to voice.name,
            "language" to language,
            "region" to voice.locale.displayCountry,
            "quality" to qualityLabel(voice.quality),
            "network" to voice.isNetworkConnectionRequired,
            "sameLanguage" to sameLanguage(voice, target),
        )
    }

    private fun openTtsSettings() {
        val intent = Intent("com.android.settings.TTS_SETTINGS")
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            context.startActivity(intent)
        } catch (_: ActivityNotFoundException) {
            throw IllegalStateException("speech settings are not available")
        }
    }

    /// [setLanguage] after [TextToSpeech.setVoice] clears the chosen voice
    /// on some engines, so language is only the fallback when no voice matches.
    private fun prepareEngine(engine: TextToSpeech) {
        engine.setAudioAttributes(
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build()
        )
        engine.setSpeechRate(1.0f)
        engine.setPitch(1.0f)
        val chosen = chooseVoice(engine)
        if (chosen != null) {
            engine.voice = chosen
        } else {
            engine.language = Locale.getDefault()
        }
    }

    private fun chooseVoice(engine: TextToSpeech): Voice? {
        val voices = engine.voices ?: return null
        val requested = requestedVoice
        if (requested.isNotEmpty()) {
            val match = voices.firstOrNull { it.name == requested && usable(it) }
            if (match != null) {
                if (match.isNetworkConnectionRequired && !online()) {
                    return bestVoice(voices, allowNetwork = false) ?: match
                }
                return match
            }
        }
        return bestVoice(voices, allowNetwork = online())
    }

    private fun bestVoice(voices: Collection<Voice>, allowNetwork: Boolean): Voice? {
        val target = Locale.getDefault()
        val usableVoices = voices.filter { usable(it) }
        val same = usableVoices.filter { sameLanguage(it, target) }
        val pool = if (same.isNotEmpty()) same else usableVoices
        val local = pool.filter { !it.isNetworkConnectionRequired }
        val ranked = when {
            allowNetwork -> pool
            local.isNotEmpty() -> local
            else -> pool
        }
        return ranked.maxWithOrNull(
            compareBy<Voice> { voiceScore(it, target, allowNetwork) }
                .thenBy { -it.latency }
                .thenBy { it.name }
        )
    }

    private fun utter(engine: TextToSpeech, text: String): Int {
        var code = engine.speak(text, TextToSpeech.QUEUE_FLUSH, null, UTTERANCE)
        if (code == TextToSpeech.ERROR) {
            val local = bestVoice(engine.voices ?: emptySet(), allowNetwork = false)
            if (local != null && local.name != engine.voice?.name) {
                engine.voice = local
                code = engine.speak(text, TextToSpeech.QUEUE_FLUSH, null, UTTERANCE)
            }
        }
        return code
    }

    private fun utteranceListener(generation: Int) = object : UtteranceProgressListener() {
        override fun onStart(utteranceId: String?) {}

        override fun onDone(utteranceId: String?) {
            if (utteranceId == UTTERANCE) {
                main.post {
                    if (generation == speakGeneration) finishPendingSpeak()
                }
            }
        }

        @Deprecated("Required by UtteranceProgressListener")
        override fun onError(utteranceId: String?) {
            if (utteranceId == UTTERANCE) {
                main.post {
                    if (generation == speakGeneration) finishPendingSpeak()
                }
            }
        }

        override fun onError(utteranceId: String?, errorCode: Int) {
            onError(utteranceId)
        }
    }

    private fun usable(voice: Voice): Boolean {
        val features = voice.features ?: emptySet()
        if (features.contains(TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED)) return false
        return !voice.locale?.language.isNullOrBlank()
    }

    private fun sameLanguage(voice: Voice, target: Locale): Boolean {
        return voice.locale?.language.equals(target.language, ignoreCase = true)
    }

    /// Higher is better. A network voice gets a modest bump when online so a
    /// high-quality online voice beats the compact on-device voice, while a
    /// very-high local voice still wins over a merely high online one.
    private fun voiceScore(voice: Voice, target: Locale, allowNetwork: Boolean): Int {
        var score = voice.quality
        if (voice.locale?.country.equals(target.country, ignoreCase = true)) score += 30
        if (voice.isNetworkConnectionRequired) score += if (allowNetwork) 50 else -1000
        return score
    }

    private fun qualityLabel(quality: Int): String = when {
        quality >= Voice.QUALITY_VERY_HIGH -> "Very high"
        quality >= Voice.QUALITY_HIGH -> "High"
        quality >= Voice.QUALITY_NORMAL -> "Normal"
        quality >= Voice.QUALITY_LOW -> "Low"
        else -> "Very low"
    }

    private fun online(): Boolean {
        val manager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return false
        val network = manager.activeNetwork ?: return false
        val caps = manager.getNetworkCapabilities(network) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
    }

    private fun sanitizeVoice(raw: String): String {
        val name = raw.trim()
        if (name.isEmpty() || name.length > 160) return ""
        if (name.any { unit ->
                val code = unit.code
                code < 0x21 || code > 0x7e || unit == '"' || unit == '\'' || unit == '/' || unit == '\\'
            }
        ) {
            return ""
        }
        return name
    }

    private fun finishPendingSpeak() {
        val pending = synchronized(speakLock) {
            val current = pendingSpeak
            pendingSpeak = null
            current
        } ?: return
        val complete = Runnable {
            try {
                pending.success(null)
            } catch (_: IllegalStateException) {
                // The result was already completed.
            }
        }
        if (Looper.myLooper() == Looper.getMainLooper()) complete.run() else main.post(complete)
    }

    private fun dispatch(command: String, params: Map<String, Any?>): Map<String, Any?> {
        return when (command) {
            "phone.open_url" -> openUrl(params.string("url"))
            "phone.launch_app" -> launchApp(params.string("name"))
            "phone.list_apps" -> mapOf("apps" to listApps())
            "phone.clipboard" -> clipboard(params.string("action"), params.string("text"))
            "phone.flashlight" -> flashlight(params["on"] == true)
            "phone.volume" -> volume(params.int("level"), params.string("stream"))
            "phone.brightness" -> brightness(params.int("level"), params.string("mode"))
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
            "phone.ringer" -> ringer(params.string("action"), params.string("mode"))
            "phone.vibrate" -> vibrate(params.int("ms"))
            "phone.dnd" -> dnd(params.string("action"), params.string("mode"))
            "phone.rotation" -> rotation(params.string("action"), params.string("mode"))
            "phone.radio" -> radio(params.string("kind"), params.string("action"))
            "phone.settings" -> settingsPage(params.string("page"), params.string("package"))
            "phone.timer" -> timer(params.int("seconds"), params.string("message"))
            "phone.device" -> deviceSnapshot()
            "phone.screen" -> screen(params.string("action"))
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
        val id = manager.cameraIdList.firstOrNull { cameraId ->
            manager.getCameraCharacteristics(cameraId)
                .get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true
        } ?: throw IllegalStateException("no flashlight")
        manager.setTorchMode(id, on)
        return mapOf("on" to on)
    }

    private fun volume(level: Int, streamName: String): Map<String, Any?> {
        val audio = context.getSystemService(AudioManager::class.java)
            ?: throw IllegalStateException("no audio")
        val name = streamName.ifBlank { "music" }
        val stream = when (name) {
            "music" -> AudioManager.STREAM_MUSIC
            "ring" -> AudioManager.STREAM_RING
            "alarm" -> AudioManager.STREAM_ALARM
            "notification" -> AudioManager.STREAM_NOTIFICATION
            "voice" -> AudioManager.STREAM_VOICE_CALL
            else -> throw IllegalArgumentException(
                "stream must be music, ring, alarm, notification, or voice"
            )
        }
        val percent = level.coerceIn(0, 100)
        val max = audio.getStreamMaxVolume(stream).coerceAtLeast(1)
        val scaled = (percent / 100.0 * max).toInt()
        audio.setStreamVolume(stream, scaled, 0)
        return mapOf("level" to percent, "stream" to name)
    }

    private fun brightness(level: Int, mode: String): Map<String, Any?> {
        if (!Settings.System.canWrite(context)) {
            startSettings(writeSettingsIntent())
            throw IllegalStateException(
                "allow Muse Companion to modify system settings, then set brightness again"
            )
        }
        val resolver = context.contentResolver
        if (mode == "auto") {
            Settings.System.putInt(
                resolver,
                Settings.System.SCREEN_BRIGHTNESS_MODE,
                Settings.System.SCREEN_BRIGHTNESS_MODE_AUTOMATIC,
            )
            return mapOf("mode" to "auto")
        }
        if (mode.isNotEmpty() && mode != "manual") {
            throw IllegalArgumentException("mode must be auto or manual")
        }
        val percent = level.coerceIn(0, 100)
        Settings.System.putInt(
            resolver,
            Settings.System.SCREEN_BRIGHTNESS_MODE,
            Settings.System.SCREEN_BRIGHTNESS_MODE_MANUAL,
        )
        val value = (percent / 100.0 * 255).toInt()
        Settings.System.putInt(resolver, Settings.System.SCREEN_BRIGHTNESS, value)
        return mapOf("level" to percent, "mode" to "manual")
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

    private fun ringer(action: String, mode: String): Map<String, Any?> {
        val audio = context.getSystemService(AudioManager::class.java)
            ?: throw IllegalStateException("no audio")
        if (action == "set") {
            val value = when (mode) {
                "normal" -> AudioManager.RINGER_MODE_NORMAL
                "vibrate" -> AudioManager.RINGER_MODE_VIBRATE
                "silent" -> AudioManager.RINGER_MODE_SILENT
                else -> throw IllegalArgumentException("mode must be normal, vibrate, or silent")
            }
            try {
                audio.ringerMode = value
            } catch (_: SecurityException) {
                startSettings(Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS))
                throw IllegalStateException(
                    "allow Muse Companion to change Do Not Disturb, then set the ringer again"
                )
            }
        }
        val current = when (audio.ringerMode) {
            AudioManager.RINGER_MODE_SILENT -> "silent"
            AudioManager.RINGER_MODE_VIBRATE -> "vibrate"
            else -> "normal"
        }
        return mapOf("mode" to current)
    }

    private fun vibrate(ms: Int): Map<String, Any?> {
        val vibrator = if (Build.VERSION.SDK_INT >= 31) {
            context.getSystemService(VibratorManager::class.java)?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            context.getSystemService(Vibrator::class.java)
        } ?: throw IllegalStateException("no vibrator")
        val duration = (if (ms <= 0) 200 else ms).coerceIn(1, 5000).toLong()
        if (Build.VERSION.SDK_INT >= 26) {
            vibrator.vibrate(VibrationEffect.createOneShot(duration, VibrationEffect.DEFAULT_AMPLITUDE))
        } else {
            @Suppress("DEPRECATION")
            vibrator.vibrate(duration)
        }
        return mapOf("ms" to duration)
    }

    private fun dnd(action: String, mode: String): Map<String, Any?> {
        val manager = context.getSystemService(NotificationManager::class.java)
            ?: throw IllegalStateException("no notifications")
        if (Build.VERSION.SDK_INT >= 23 && !manager.isNotificationPolicyAccessGranted) {
            startSettings(Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS))
            throw IllegalStateException(
                "allow Muse Companion to change Do Not Disturb, then try again"
            )
        }
        if (action == "set") {
            val filter = when (mode) {
                "none", "silent" -> NotificationManager.INTERRUPTION_FILTER_NONE
                "priority" -> NotificationManager.INTERRUPTION_FILTER_PRIORITY
                "alarms" -> NotificationManager.INTERRUPTION_FILTER_ALARMS
                "all", "off" -> NotificationManager.INTERRUPTION_FILTER_ALL
                else -> throw IllegalArgumentException("mode must be all, priority, alarms, or none")
            }
            manager.setInterruptionFilter(filter)
        }
        val current = when (manager.currentInterruptionFilter) {
            NotificationManager.INTERRUPTION_FILTER_NONE -> "none"
            NotificationManager.INTERRUPTION_FILTER_PRIORITY -> "priority"
            NotificationManager.INTERRUPTION_FILTER_ALARMS -> "alarms"
            else -> "all"
        }
        return mapOf("mode" to current, "granted" to true)
    }

    private fun rotation(action: String, mode: String): Map<String, Any?> {
        if (!Settings.System.canWrite(context)) {
            startSettings(writeSettingsIntent())
            throw IllegalStateException(
                "allow Muse Companion to modify system settings, then set rotation again"
            )
        }
        val resolver = context.contentResolver
        if (action == "set") {
            when (mode) {
                "auto" -> Settings.System.putInt(resolver, Settings.System.ACCELEROMETER_ROTATION, 1)
                "portrait" -> {
                    Settings.System.putInt(resolver, Settings.System.ACCELEROMETER_ROTATION, 0)
                    Settings.System.putInt(resolver, Settings.System.USER_ROTATION, Surface.ROTATION_0)
                }
                "landscape" -> {
                    Settings.System.putInt(resolver, Settings.System.ACCELEROMETER_ROTATION, 0)
                    Settings.System.putInt(resolver, Settings.System.USER_ROTATION, Surface.ROTATION_90)
                }
                "locked" -> Settings.System.putInt(resolver, Settings.System.ACCELEROMETER_ROTATION, 0)
                else -> throw IllegalArgumentException(
                    "mode must be auto, portrait, landscape, or locked"
                )
            }
        }
        val auto = Settings.System.getInt(resolver, Settings.System.ACCELEROMETER_ROTATION, 0) == 1
        val user = Settings.System.getInt(resolver, Settings.System.USER_ROTATION, 0)
        val current = when {
            auto -> "auto"
            user == Surface.ROTATION_90 || user == Surface.ROTATION_270 -> "landscape"
            else -> "portrait"
        }
        return mapOf("mode" to current, "auto" to auto)
    }

    private fun radio(kind: String, action: String): Map<String, Any?> {
        val status = when (kind) {
            "wifi" -> wifiStatus()
            "bluetooth" -> bluetoothStatus()
            "nfc" -> nfcStatus()
            "airplane" -> mapOf(
                "kind" to "airplane",
                "available" to true,
                "enabled" to airplaneOn(),
            )
            "mobile" -> mobileStatus()
            else -> throw IllegalArgumentException(
                "kind must be wifi, bluetooth, nfc, airplane, or mobile"
            )
        }
        if (action == "open") {
            openRadio(kind)
            return status + mapOf("opened" to true)
        }
        return status + mapOf("opened" to false)
    }

    private fun settingsPage(page: String, packageName: String): Map<String, Any?> {
        val intent = when (page) {
            "wifi" -> Intent(Settings.ACTION_WIFI_SETTINGS)
            "bluetooth" -> Intent(Settings.ACTION_BLUETOOTH_SETTINGS)
            "nfc" -> Intent(Settings.ACTION_NFC_SETTINGS)
            "display" -> Intent(Settings.ACTION_DISPLAY_SETTINGS)
            "sound" -> Intent(Settings.ACTION_SOUND_SETTINGS)
            "apps" -> Intent(Settings.ACTION_APPLICATION_SETTINGS)
            "battery" -> Intent(Settings.ACTION_BATTERY_SAVER_SETTINGS)
            "location" -> Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS)
            "notifications" -> appNotificationSettings()
            "wireless" -> Intent(Settings.ACTION_WIRELESS_SETTINGS)
            "date" -> Intent(Settings.ACTION_DATE_SETTINGS)
            "accessibility" -> Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
            "storage" -> Intent(Settings.ACTION_INTERNAL_STORAGE_SETTINGS)
            "about" -> Intent(Settings.ACTION_DEVICE_INFO_SETTINGS)
            "dnd" -> Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS)
            "airplane" -> Intent(Settings.ACTION_AIRPLANE_MODE_SETTINGS)
            "data" -> Intent(Settings.ACTION_DATA_USAGE_SETTINGS)
            "security" -> Intent(Settings.ACTION_SECURITY_SETTINGS)
            "write" -> writeSettingsIntent()
            "app" -> Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                val pkg = packageName.ifBlank { context.packageName }
                data = android.net.Uri.parse("package:$pkg")
            }
            else -> throw IllegalArgumentException(
                "page must be wifi, bluetooth, nfc, display, sound, apps, battery, " +
                    "location, notifications, wireless, date, accessibility, storage, " +
                    "about, dnd, airplane, data, security, write, or app"
            )
        }
        startSettings(intent)
        return mapOf("status" to "opened", "page" to page)
    }

    private fun timer(seconds: Int, message: String): Map<String, Any?> {
        require(seconds in 1..86_400) { "seconds must be 1 to 86400" }
        val intent = Intent(AlarmClock.ACTION_SET_TIMER).apply {
            putExtra(AlarmClock.EXTRA_LENGTH, seconds)
            putExtra(AlarmClock.EXTRA_MESSAGE, message.ifBlank { "Muse" })
            putExtra(AlarmClock.EXTRA_SKIP_UI, true)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        context.startActivity(intent)
        return mapOf("status" to "set", "seconds" to seconds)
    }

    private fun deviceSnapshot(): Map<String, Any?> {
        val battery = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val level = battery?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = battery?.getIntExtra(BatteryManager.EXTRA_SCALE, 100) ?: 100
        val status = battery?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
        val charging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
            status == BatteryManager.BATTERY_STATUS_FULL
        val percent = if (level >= 0 && scale > 0) (level * 100) / scale else -1
        val stat = StatFs(Environment.getDataDirectory().path)
        val power = context.getSystemService(PowerManager::class.java)
        val rotation = when (activity.display?.rotation ?: Surface.ROTATION_0) {
            Surface.ROTATION_90, Surface.ROTATION_270 -> "landscape"
            else -> "portrait"
        }
        return mapOf(
            "manufacturer" to Build.MANUFACTURER,
            "model" to Build.MODEL,
            "device" to Build.DEVICE,
            "release" to Build.VERSION.RELEASE,
            "sdk" to Build.VERSION.SDK_INT,
            "battery_percent" to percent,
            "charging" to charging,
            "storage_free_bytes" to stat.availableBytes,
            "storage_total_bytes" to stat.totalBytes,
            "screen_on" to (power?.isInteractive == true),
            "orientation" to rotation,
            "ringer" to ringer("get", ""),
            "wifi" to wifiStatus(),
            "bluetooth" to bluetoothStatus(),
            "nfc" to nfcStatus(),
            "airplane" to airplaneOn(),
            "write_settings" to Settings.System.canWrite(context),
            "dnd" to dndGranted(),
        )
    }

    @Suppress("DEPRECATION")
    private fun screen(action: String): Map<String, Any?> {
        val power = context.getSystemService(PowerManager::class.java)
        if (action == "wake") {
            val lock = power?.newWakeLock(
                PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP,
                "muse:screen",
            )
            lock?.acquire(3_000)
            context.startActivity(
                Intent(context, MainActivity::class.java).addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                )
            )
            if (Build.VERSION.SDK_INT >= 27) activity.setTurnScreenOn(true)
        } else if (action.isNotEmpty() && action != "status") {
            throw IllegalArgumentException("action must be status or wake")
        }
        return mapOf("screen_on" to (power?.isInteractive == true))
    }

    private fun wifiStatus(): Map<String, Any?> {
        val wifi = context.applicationContext.getSystemService(WifiManager::class.java)
        val connected = activeTransport(NetworkCapabilities.TRANSPORT_WIFI)
        return mapOf(
            "kind" to "wifi",
            "available" to (wifi != null),
            "enabled" to (wifi?.isWifiEnabled == true),
            "connected" to connected,
        )
    }

    private fun bluetoothStatus(): Map<String, Any?> {
        val adapter = context.getSystemService(BluetoothManager::class.java)?.adapter
        val enabled = try {
            adapter?.isEnabled == true
        } catch (_: SecurityException) {
            false
        }
        return mapOf(
            "kind" to "bluetooth",
            "available" to (adapter != null),
            "enabled" to enabled,
        )
    }

    private fun nfcStatus(): Map<String, Any?> {
        val adapter = NfcAdapter.getDefaultAdapter(context)
        return mapOf(
            "kind" to "nfc",
            "available" to (adapter != null),
            "enabled" to (adapter?.isEnabled == true),
        )
    }

    private fun mobileStatus(): Map<String, Any?> = mapOf(
        "kind" to "mobile",
        "available" to context.packageManager.hasSystemFeature(PackageManager.FEATURE_TELEPHONY),
        "connected" to activeTransport(NetworkCapabilities.TRANSPORT_CELLULAR),
    )

    private fun activeTransport(transport: Int): Boolean {
        val manager = context.getSystemService(ConnectivityManager::class.java) ?: return false
        val network = manager.activeNetwork ?: return false
        val caps = manager.getNetworkCapabilities(network) ?: return false
        return caps.hasTransport(transport)
    }

    private fun airplaneOn(): Boolean =
        Settings.Global.getInt(context.contentResolver, Settings.Global.AIRPLANE_MODE_ON, 0) == 1

    private fun openRadio(kind: String) {
        if (Build.VERSION.SDK_INT >= 29) {
            val panel = when (kind) {
                "wifi" -> Settings.Panel.ACTION_WIFI
                "nfc" -> Settings.Panel.ACTION_NFC
                "mobile" -> Settings.Panel.ACTION_INTERNET_CONNECTIVITY
                else -> null
            }
            if (panel != null) {
                startSettings(Intent(panel))
                return
            }
        }
        val page = when (kind) {
            "wifi" -> "wifi"
            "bluetooth" -> "bluetooth"
            "nfc" -> "nfc"
            "airplane" -> "airplane"
            "mobile" -> "data"
            else -> throw IllegalArgumentException(
                "kind must be wifi, bluetooth, nfc, airplane, or mobile"
            )
        }
        settingsPage(page, "")
    }

    private fun writeSettingsIntent(): Intent =
        Intent(Settings.ACTION_MANAGE_WRITE_SETTINGS).apply {
            data = android.net.Uri.parse("package:${context.packageName}")
        }

    private fun appNotificationSettings(): Intent =
        Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
            if (Build.VERSION.SDK_INT >= 26) {
                putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
            } else {
                putExtra("app_package", context.packageName)
            }
        }

    private fun startSettings(intent: Intent) {
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
    }

    private fun dndGranted(): Boolean {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return false
        return manager.isNotificationPolicyAccessGranted
    }

    private fun hasCamera(facing: Int): Boolean {
        val manager = context.getSystemService(CameraManager::class.java) ?: return false
        return manager.cameraIdList.any { id ->
            manager.getCameraCharacteristics(id).get(CameraCharacteristics.LENS_FACING) == facing
        }
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
            "camera_back" to hasCamera(CameraCharacteristics.LENS_FACING_BACK),
            "camera_front" to hasCamera(CameraCharacteristics.LENS_FACING_FRONT),
            "microphone" to granted(Manifest.permission.RECORD_AUDIO),
            "location" to granted(Manifest.permission.ACCESS_FINE_LOCATION),
            "sms" to granted(Manifest.permission.READ_SMS),
            "phone" to granted(Manifest.permission.CALL_PHONE),
            "contacts" to granted(Manifest.permission.READ_CONTACTS),
            "calendar" to granted(Manifest.permission.READ_CALENDAR),
            "notifications" to granted(Manifest.permission.POST_NOTIFICATIONS),
            "notification_listener" to MuseNotificationListener.enabled(),
            "flashlight" to context.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_FLASH),
            "write_settings" to Settings.System.canWrite(context),
            "dnd" to dndGranted(),
            "model" to Build.MODEL,
            "manufacturer" to Build.MANUFACTURER,
            "release" to Build.VERSION.RELEASE,
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
        private const val GOOGLE_TTS = "com.google.android.tts"
        private const val UTTERANCE = "muse-reply"
    }
}
