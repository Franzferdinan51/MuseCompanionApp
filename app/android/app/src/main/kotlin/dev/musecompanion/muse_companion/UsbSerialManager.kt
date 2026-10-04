package dev.musecompanion.muse_companion

import android.content.Context
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbManager
import android.os.SystemClock
import android.util.Base64
import android.util.Log
import com.hoho.android.usbserial.driver.UsbSerialDriver
import com.hoho.android.usbserial.driver.UsbSerialPort
import com.hoho.android.usbserial.driver.UsbSerialProber
import java.io.ByteArrayOutputStream
import java.nio.charset.CodingErrorAction

/**
 * USB serial support for generic USB serial devices plugged in over OTG:
 * dev boards, routers, 3D printers, ham radios, GPS units, industrial
 * gear, or anything else with a serial console. Uses the
 * usb-serial-for-android driver library, whose [UsbSerialProber]
 * recognizes CDC-ACM, FTDI, CP210x, CH340 and PL2303 chips generically —
 * no per-device code is needed.
 *
 * Open ports are tracked by session id, so several devices (or several
 * ports on one device) can be open at once.
 *
 * USB permission is not requested here; it goes through [UsbOtgManager]'s
 * existing permission flow (`usb.request_permission`). Opening a port
 * without permission returns an error saying so.
 */
class UsbSerialManager(private val context: Context) {

    private val usbManager: UsbManager? =
        context.getSystemService(UsbManager::class.java)
    private val prober: UsbSerialProber = UsbSerialProber.getDefaultProber()

    private data class Session(
        val id: String,
        val deviceName: String,
        val port: UsbSerialPort,
        val connection: UsbDeviceConnection,
        val driverName: String,
        var baudRate: Int,
        val dataBits: Int = 8,
        val stopBits: Int = UsbSerialPort.STOPBITS_1,
        val parity: Int = UsbSerialPort.PARITY_NONE,
    )

    private val sessions = mutableMapOf<String, Session>()
    private var nextSessionId = 1

    /** Every attached USB device the prober recognizes as a serial port. */
    fun listPorts(): List<Map<String, Any?>> {
        val um = usbManager ?: return emptyList()
        val out = mutableListOf<Map<String, Any?>>()
        for (device in um.deviceList.values.sortedBy { it.deviceName }) {
            val driver = try {
                prober.probeDevice(device)
            } catch (_: Exception) {
                null
            } ?: continue
            for (port in driver.ports) {
                out.add(
                    mapOf(
                        "device" to device.deviceName,
                        "name" to (device.productName ?: device.deviceName),
                        "manufacturer" to (device.manufacturerName ?: ""),
                        "driver" to friendlyDriverName(driver),
                        "port" to port.portNumber,
                        "vendor_id" to device.vendorId,
                        "product_id" to device.productId,
                        "has_permission" to um.hasPermission(device),
                    ),
                )
            }
        }
        return out
    }

    /**
     * Open [portIndex] of the serial device at [deviceName] at [baudRate]
     * (8 data bits, 1 stop bit, no parity). Returns a session id, or an
     * error — notably when USB permission has not been granted yet, in
     * which case Muse should call `usb.request_permission` first.
     */
    fun open(deviceName: String, portIndex: Int, baudRate: Int): Map<String, Any?> {
        val um = usbManager ?: return mapOf("error" to "no USB manager")
        val device = um.deviceList.values.firstOrNull { it.deviceName == deviceName }
            ?: return mapOf("error" to "no such USB device: $deviceName")
        if (!um.hasPermission(device)) {
            return mapOf(
                "error" to "no USB permission for $deviceName; " +
                    "call usb.request_permission with this device name first",
            )
        }
        val driver = try {
            prober.probeDevice(device)
        } catch (e: Exception) {
            return mapOf("error" to "not a recognized serial device: ${e.message}")
        } ?: return mapOf("error" to "no serial driver for $deviceName")
        val idx = portIndex.coerceAtLeast(0)
        if (idx >= driver.ports.size) {
            return mapOf(
                "error" to "device has ${driver.ports.size} port(s), no port $idx",
            )
        }
        val port = driver.ports[idx]
        val connection = um.openDevice(device)
            ?: return mapOf("error" to "could not open USB connection for $deviceName")
        val baud = if (baudRate > 0) baudRate else DEFAULT_BAUD
        val driverName = friendlyDriverName(driver)
        return try {
            port.open(connection)
            port.setParameters(
                baud, 8, UsbSerialPort.STOPBITS_1, UsbSerialPort.PARITY_NONE,
            )
            val id = (nextSessionId++).toString()
            sessions[id] = Session(
                id = id,
                deviceName = deviceName,
                port = port,
                connection = connection,
                driverName = driverName,
                baudRate = baud,
            )
            Log.i(TAG, "serial opened: $deviceName port $idx @ $baud (session $id)")
            mapOf(
                "session" to id,
                "device" to deviceName,
                "port" to idx,
                "driver" to driverName,
                "baud_rate" to baud,
            )
        } catch (e: Exception) {
            try {
                connection.close()
            } catch (_: Exception) {
            }
            mapOf("error" to "could not open serial port: ${e.message}")
        }
    }

    /**
     * Write bytes to the port. [encoding] is "utf8" (default) or "base64"
     * for binary payloads.
     */
    fun write(sessionId: String, data: String, encoding: String): Map<String, Any?> {
        val bytes = try {
            if (encoding == "base64") Base64.decode(data, Base64.DEFAULT)
            else data.toByteArray(Charsets.UTF_8)
        } catch (e: Exception) {
            return mapOf("error" to "cannot decode write data: ${e.message}")
        }
        return writeBytes(sessionId, bytes)
    }

    /**
     * [write] with a trailing newline appended. Most firmware consoles
     * expect newline-terminated commands.
     */
    fun writeLine(sessionId: String, data: String, encoding: String): Map<String, Any?> {
        val base = try {
            if (encoding == "base64") Base64.decode(data, Base64.DEFAULT)
            else data.toByteArray(Charsets.UTF_8)
        } catch (e: Exception) {
            return mapOf("error" to "cannot decode write data: ${e.message}")
        }
        return writeBytes(sessionId, base + '\n'.code.toByte())
    }

    private fun writeBytes(sessionId: String, bytes: ByteArray): Map<String, Any?> {
        val s = sessions[sessionId] ?: return unknownSession(sessionId)
        return try {
            val n = s.port.write(bytes, WRITE_TIMEOUT_MS)
            mapOf("session" to sessionId, "bytes_written" to n)
        } catch (e: Exception) {
            mapOf("error" to "serial write failed: ${e.message}")
        }
    }

    /**
     * Read once, waiting up to [timeoutMs]. Returns the byte count plus
     * the data as base64 and as a UTF-8 text decode.
     */
    fun read(sessionId: String, timeoutMs: Int): Map<String, Any?> {
        val s = sessions[sessionId] ?: return unknownSession(sessionId)
        val timeout = timeoutMs.coerceIn(100, MAX_READ_TIMEOUT_MS)
        return try {
            val buf = ByteArray(READ_CHUNK)
            val n = s.port.read(buf, timeout)
            mapOf(
                "session" to sessionId,
                "bytes" to n,
                "base64" to Base64.encodeToString(buf, 0, n, Base64.NO_WRAP),
                "text" to decodeText(buf, 0, n),
            )
        } catch (e: Exception) {
            mapOf("error" to "serial read failed: ${e.message}")
        }
    }

    /**
     * Read up to [maxLines] newline-terminated lines, waiting until they
     * arrive or [timeoutMs] elapses. Returns the lines as a list plus any
     * partial (unterminated) line still in the buffer.
     */
    fun readLines(sessionId: String, maxLines: Int, timeoutMs: Int): Map<String, Any?> {
        val s = sessions[sessionId] ?: return unknownSession(sessionId)
        val want = maxLines.coerceIn(1, MAX_LINES)
        val deadline = SystemClock.uptimeMillis() + timeoutMs.coerceIn(100, MAX_READ_TIMEOUT_MS)
        val raw = ByteArrayOutputStream()
        val lines = mutableListOf<String>()
        try {
            val buf = ByteArray(READ_CHUNK)
            while (lines.size < want && SystemClock.uptimeMillis() < deadline) {
                val remaining =
                    (deadline - SystemClock.uptimeMillis()).toInt().coerceAtLeast(1)
                val n = s.port.read(buf, remaining.coerceAtMost(POLL_MS))
                if (n <= 0) continue
                var start = 0
                for (i in 0 until n) {
                    if (buf[i] == '\n'.code.toByte()) {
                        raw.write(buf, start, i - start)
                        lines.add(decodeText(raw.toByteArray()).trimEnd('\r'))
                        raw.reset()
                        start = i + 1
                        if (lines.size >= want) break
                    }
                }
                if (start < n) raw.write(buf, start, n - start)
            }
        } catch (e: Exception) {
            return mapOf("error" to "serial read_lines failed: ${e.message}")
        }
        return mapOf(
            "session" to sessionId,
            "lines" to lines,
            "count" to lines.size,
            "partial" to decodeText(raw.toByteArray()),
        )
    }

    /**
     * Discard all buffered input on the port. Returns how many bytes were
     * dropped. Useful before sending a fresh command so the reply is not
     * polluted by stale output.
     */
    fun drain(sessionId: String): Map<String, Any?> {
        val s = sessions[sessionId] ?: return unknownSession(sessionId)
        var dropped = 0
        return try {
            val buf = ByteArray(READ_CHUNK)
            while (true) {
                val n = s.port.read(buf, DRAIN_POLL_MS)
                if (n <= 0) break
                dropped += n
            }
            mapOf("session" to sessionId, "bytes_dropped" to dropped)
        } catch (e: Exception) {
            mapOf("error" to "serial drain failed: ${e.message}")
        }
    }

    /** Change the baud rate on an already-open port (keeps 8N1). */
    fun setBaud(sessionId: String, baudRate: Int): Map<String, Any?> {
        val s = sessions[sessionId] ?: return unknownSession(sessionId)
        if (baudRate <= 0) return mapOf("error" to "baud_rate must be positive")
        return try {
            s.port.setParameters(baudRate, s.dataBits, s.stopBits, s.parity)
            s.baudRate = baudRate
            mapOf("session" to sessionId, "baud_rate" to baudRate)
        } catch (e: Exception) {
            mapOf("error" to "could not set baud rate: ${e.message}")
        }
    }

    /**
     * Drive the DTR and RTS control lines on an open port. This is generic
     * serial line control — toggling these sequences is how many devices
     * are reset or put into firmware-download mode.
     */
    fun setDtrRts(sessionId: String, dtr: Boolean, rts: Boolean): Map<String, Any?> {
        val s = sessions[sessionId] ?: return unknownSession(sessionId)
        return try {
            s.port.setDTR(dtr)
            s.port.setRTS(rts)
            mapOf("session" to sessionId, "dtr" to dtr, "rts" to rts)
        } catch (e: Exception) {
            mapOf("error" to "could not set DTR/RTS: ${e.message}")
        }
    }

    /**
     * Report an open port: driver, baud rate, data/stop/parity, and the
     * CTS/DSR line state where the driver supports it (null otherwise).
     */
    fun portInfo(sessionId: String): Map<String, Any?> {
        val s = sessions[sessionId] ?: return unknownSession(sessionId)
        return mapOf(
            "session" to sessionId,
            "device" to s.deviceName,
            "driver" to s.driverName,
            "baud_rate" to s.baudRate,
            "data_bits" to s.dataBits,
            "stop_bits" to s.stopBits,
            "parity" to parityName(s.parity),
            "cts" to runCatching { s.port.cts }.getOrNull(),
            "dsr" to runCatching { s.port.dsr }.getOrNull(),
        )
    }

    /**
     * Purge the port's hardware buffers. [direction] is "rx", "tx", or
     * "both" (default).
     */
    fun purge(sessionId: String, direction: String): Map<String, Any?> {
        val s = sessions[sessionId] ?: return unknownSession(sessionId)
        val dir = direction.lowercase()
        val (purgeWrite, purgeRead) = when (dir) {
            "rx" -> false to true
            "tx" -> true to false
            "both" -> true to true
            else -> return mapOf("error" to "direction must be rx, tx or both")
        }
        return try {
            val ok = s.port.purgeHwBuffers(purgeWrite, purgeRead)
            mapOf("session" to sessionId, "direction" to dir, "ok" to ok)
        } catch (e: Exception) {
            mapOf("error" to "serial purge failed: ${e.message}")
        }
    }

    /** Close the port and release its session. */
    fun close(sessionId: String): Map<String, Any?> {
        val s = sessions.remove(sessionId) ?: return unknownSession(sessionId)
        return try {
            s.port.close()
            Log.i(TAG, "serial closed: ${s.deviceName} (session $sessionId)")
            mapOf("session" to sessionId, "status" to "closed")
        } catch (e: Exception) {
            mapOf(
                "session" to sessionId,
                "status" to "closed_with_error",
                "detail" to e.message,
            )
        }
    }

    private fun unknownSession(sessionId: String): Map<String, Any?> =
        mapOf("error" to "unknown serial session: $sessionId")

    private fun friendlyDriverName(driver: UsbSerialDriver): String {
        return when (driver.javaClass.simpleName) {
            "CdcAcmSerialDriver" -> "CDC-ACM"
            "FtdiSerialDriver" -> "FTDI"
            "Cp21xxSerialDriver" -> "CP210x"
            "Ch34xSerialDriver" -> "CH340"
            "Pl2303SerialDriver" -> "PL2303"
            "ProlificSerialDriver" -> "Prolific"
            else -> driver.javaClass.simpleName.removeSuffix("SerialDriver")
        }
    }

    private fun parityName(parity: Int): String = when (parity) {
        UsbSerialPort.PARITY_ODD -> "odd"
        UsbSerialPort.PARITY_EVEN -> "even"
        UsbSerialPort.PARITY_MARK -> "mark"
        UsbSerialPort.PARITY_SPACE -> "space"
        else -> "none"
    }

    private fun decodeText(bytes: ByteArray, offset: Int = 0, length: Int = bytes.size): String =
        Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPLACE)
            .onUnmappableCharacter(CodingErrorAction.REPLACE)
            .decode(java.nio.ByteBuffer.wrap(bytes, offset, length))
            .toString()

    companion object {
        private const val TAG = "MuseUsbSerial"
        private const val DEFAULT_BAUD = 115200
        private const val WRITE_TIMEOUT_MS = 2000
        private const val MAX_READ_TIMEOUT_MS = 30_000
        private const val POLL_MS = 250
        private const val DRAIN_POLL_MS = 100
        private const val READ_CHUNK = 4096
        private const val MAX_LINES = 200
    }
}
