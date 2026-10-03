package dev.musecompanion.muse_companion

import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

class MainActivity : FlutterActivity() {
    companion object {
        private const val TAG = "GadgetBleChannel"
        private const val METHOD_CHANNEL = "dev.musecompanion/ble"
        private const val EVENT_CHANNEL = "dev.musecompanion/ble_events"
    }

    private var peripheral: GadgetBlePeripheral? = null
    private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        hideSystemBars()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) hideSystemBars()
    }

    private fun hideSystemBars() {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        val controller = WindowInsetsControllerCompat(window, window.decorView)
        controller.hide(WindowInsetsCompat.Type.systemBars())
        controller.systemBarsBehavior =
            WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        peripheral = GadgetBlePeripheral(applicationContext, bleListener)
        PhoneBridge(this).register(flutterEngine.dartExecutor.binaryMessenger)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL
        ).setMethodCallHandler { call, result ->
            val peripheral = peripheral
            if (peripheral == null) {
                result.error("unavailable", "BLE peripheral not ready", null)
                return@setMethodCallHandler
            }
            try {
                when (call.method) {
                    "isSupported" -> result.success(peripheral.isSupported())
                    "isBluetoothOn" -> result.success(peripheral.isBluetoothOn())
                    "isAdvertising" -> result.success(peripheral.isAdvertising())
                    "currentMtu" -> result.success(peripheral.currentMtu())
                    "start" -> {
                        val name = call.argument<String>("name")
                        val service = call.argument<String>("serviceUuid")
                        val rx = call.argument<String>("rxUuid")
                        val tx = call.argument<String>("txUuid")
                        val paired = call.argument<Boolean>("paired") ?: false
                        if (name == null || service == null ||
                            rx == null || tx == null
                        ) {
                            result.error(
                                "args", "start needs name/paired/uuids", null)
                        } else {
                            result.success(
                                peripheral.start(
                                    name, paired,
                                    UUID.fromString(service),
                                    UUID.fromString(rx),
                                    UUID.fromString(tx),
                                )
                            )
                        }
                    }
                    "stop" -> {
                        peripheral.stop()
                        result.success(null)
                    }
                    "notify" -> {
                        val packet = call.argument<ByteArray>("packet")
                        if (packet == null) {
                            result.error("args", "notify needs packet", null)
                        } else {
                            result.success(peripheral.notify(packet))
                        }
                    }
                    "disconnect" -> {
                        peripheral.disconnect()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: SecurityException) {
                result.error("permission", e.message, null)
            } catch (e: IllegalArgumentException) {
                result.error("args", e.message, null)
            }
        }

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(
                arguments: Any?,
                events: EventChannel.EventSink?,
            ) {
                eventSink = events
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })
    }

    override fun onDestroy() {
        try {
            peripheral?.stop()
        } catch (e: SecurityException) {
            Log.w(TAG, "stop on destroy failed: ${e.message}")
        }
        peripheral = null
        super.onDestroy()
    }

    private fun emit(event: Map<String, Any?>) {
        // GATT callbacks arrive on binder threads; the sink needs the
        // platform thread.
        mainHandler.post {
            try {
                eventSink?.success(event)
            } catch (e: IllegalStateException) {
                Log.w(TAG, "event sink gone: ${e.message}")
            }
        }
    }

    private val bleListener = object : GadgetBlePeripheral.Listener {
        override fun onWrite(data: ByteArray, mtu: Int) {
            emit(mapOf("type" to "write", "data" to data, "mtu" to mtu))
        }

        override fun onConnected() {
            emit(mapOf("type" to "connected"))
        }

        override fun onDisconnected() {
            emit(mapOf("type" to "disconnected"))
        }

        override fun onMtu(mtu: Int) {
            emit(mapOf("type" to "mtu", "mtu" to mtu))
        }

        override fun onError(message: String) {
            emit(mapOf("type" to "error", "message" to message))
        }
    }
}
