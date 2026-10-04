package dev.musecompanion.muse_companion

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Environment
import android.os.StatFs
import android.os.storage.StorageManager
import android.os.storage.StorageVolume
import android.util.Base64
import android.util.Log
import androidx.core.content.ContextCompat
import java.io.File

/**
 * USB On-The-Go support: device discovery, permission, and mass-storage
 * file access for the Muse companion.
 *
 * Flash drives plugged in over OTG are mounted by Android and show up as
 * removable [StorageVolume]s, so file access goes through plain
 * [java.io.File] on the mount path (no raw bulk-transfer SCSI needed).
 * [UsbManager] is used for device discovery and the permission dialog.
 */
class UsbOtgManager(private val context: Context) {

    private val usbManager: UsbManager? =
        context.getSystemService(UsbManager::class.java)
    private val storageManager: StorageManager? =
        context.getSystemService(StorageManager::class.java)

    private var receiverRegistered = false

    private val usbReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context, intent: Intent) {
            val device = intent.usbDevice()
            when (intent.action) {
                ACTION_USB_PERMISSION -> {
                    val granted =
                        intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                    Log.i(
                        TAG,
                        "USB permission ${if (granted) "granted" else "denied"} " +
                            "for ${device?.deviceName}",
                    )
                }
                UsbManager.ACTION_USB_DEVICE_ATTACHED ->
                    Log.i(TAG, "USB attached: ${device?.deviceName}")
                UsbManager.ACTION_USB_DEVICE_DETACHED ->
                    Log.i(TAG, "USB detached: ${device?.deviceName}")
            }
        }
    }

    /** Start listening for attach/detach and permission results. */
    fun start() {
        if (receiverRegistered) return
        val filter = IntentFilter().apply {
            addAction(ACTION_USB_PERMISSION)
            addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
            addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
        }
        ContextCompat.registerReceiver(
            context,
            usbReceiver,
            filter,
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        receiverRegistered = true
    }

    fun stop() {
        if (!receiverRegistered) return
        try {
            context.unregisterReceiver(usbReceiver)
        } catch (_: Exception) {
        }
        receiverRegistered = false
    }

    fun hasUsbHost(): Boolean =
        context.packageManager.hasSystemFeature(PackageManager.FEATURE_USB_HOST)

    /** Every USB device currently on the bus. No permission needed to list. */
    fun listDevices(): List<Map<String, Any?>> {
        val um = usbManager ?: return emptyList()
        return um.deviceList.values
            .sortedBy { it.deviceName }
            .map { d ->
                mapOf(
                    "device" to d.deviceName,
                    "name" to (d.productName ?: d.deviceName),
                    "manufacturer" to (d.manufacturerName ?: ""),
                    "vendor_id" to d.vendorId,
                    "product_id" to d.productId,
                    "class" to d.deviceClass,
                    "subclass" to d.deviceSubclass,
                    "has_permission" to um.hasPermission(d),
                )
            }
    }

    /**
     * Show the system USB permission dialog for [deviceName].
     * The user's answer arrives asynchronously on the permission broadcast;
     * call [listDevices] afterwards to see `has_permission`.
     */
    fun requestPermission(deviceName: String): Map<String, Any?> {
        val um = usbManager ?: return mapOf("error" to "no USB manager")
        val device = um.deviceList.values.firstOrNull { it.deviceName == deviceName }
            ?: return mapOf("error" to "no such USB device: $deviceName")
        if (um.hasPermission(device)) {
            return mapOf("status" to "already_granted", "device" to deviceName)
        }
        val intent = Intent(ACTION_USB_PERMISSION).setPackage(context.packageName)
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            PendingIntent.FLAG_IMMUTABLE
        } else {
            0
        }
        val pi = PendingIntent.getBroadcast(context, 0, intent, flags)
        um.requestPermission(device, pi)
        return mapOf("status" to "prompt_shown", "device" to deviceName)
    }

    /**
     * Mounted removable storage volumes (USB OTG drives and SD cards):
     * path, label, and space. Only mounted volumes are returned.
     */
    fun listVolumes(): List<Map<String, Any?>> {
        val sm = storageManager ?: return emptyList()
        return sm.storageVolumes.mapNotNull { vol ->
            if (!vol.isRemovable) return@mapNotNull null
            val path = vol.volumePath() ?: return@mapNotNull null
            val state = Environment.getStorageState(File(path))
            if (state != Environment.MEDIA_MOUNTED &&
                state != Environment.MEDIA_MOUNTED_READ_ONLY
            ) {
                return@mapNotNull null
            }
            val stat = try {
                StatFs(path)
            } catch (_: Exception) {
                return@mapNotNull null
            }
            mapOf(
                "path" to path,
                "description" to vol.getDescription(context),
                "uuid" to (vol.uuid ?: ""),
                "state" to state,
                "total_bytes" to stat.totalBytes,
                "free_bytes" to stat.availableBytes,
            )
        }.sortedBy { it["path"] as String }
    }

    /** List a directory inside a mounted removable volume. Folders first. */
    fun listFiles(path: String): Map<String, Any?> {
        val dir = File(path)
        if (!insideUsbVolume(dir)) {
            return mapOf("error" to "path is not inside a mounted USB volume: $path")
        }
        if (!dir.isDirectory) {
            return mapOf("error" to "not a directory: $path")
        }
        val kids = try {
            dir.listFiles() ?: emptyArray()
        } catch (e: SecurityException) {
            return mapOf("error" to "cannot read directory: ${e.message}")
        }
        val entries = kids
            .sortedWith(compareBy({ !it.isDirectory }, { it.name.lowercase() }))
            .take(MAX_LIST_ENTRIES)
            .map { f ->
                mapOf(
                    "name" to f.name,
                    "path" to f.absolutePath,
                    "is_dir" to f.isDirectory,
                    "size" to if (f.isFile) f.length() else 0L,
                    "modified" to f.lastModified(),
                )
            }
        return mapOf(
            "path" to dir.absolutePath,
            "entries" to entries,
            "truncated" to (kids.size > MAX_LIST_ENTRIES),
        )
    }

    /**
     * Read a file from a mounted removable volume, base64-encoded.
     * Refuses files over [MAX_READ_BYTES] (10 MB).
     */
    fun readFile(path: String): Map<String, Any?> {
        val file = File(path)
        if (!insideUsbVolume(file)) {
            return mapOf("error" to "path is not inside a mounted USB volume: $path")
        }
        if (!file.isFile) {
            return mapOf("error" to "not a file: $path")
        }
        val size = file.length()
        if (size > MAX_READ_BYTES) {
            return mapOf(
                "error" to "file is ${size} bytes, over the ${MAX_READ_BYTES}-byte cap",
            )
        }
        return try {
            val bytes = file.readBytes()
            mapOf(
                "name" to file.name,
                "path" to file.absolutePath,
                "size" to bytes.size.toLong(),
                "base64" to Base64.encodeToString(bytes, Base64.NO_WRAP),
            )
        } catch (e: Exception) {
            mapOf("error" to "cannot read file: ${e.message}")
        }
    }

    /** True when [file]'s canonical path sits under a mounted USB volume. */
    private fun insideUsbVolume(file: File): Boolean {
        val roots = listVolumes().mapNotNull { it["path"] as? String }
        val target = try {
            file.canonicalPath
        } catch (_: Exception) {
            return false
        }
        return roots.any { root ->
            val canonicalRoot = try {
                File(root).canonicalPath
            } catch (_: Exception) {
                return@any false
            }
            target == canonicalRoot || target.startsWith("$canonicalRoot/")
        }
    }

    private fun StorageVolume.volumePath(): String? {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                directory?.absolutePath
            } else {
                @Suppress("DiscouragedPrivateApi")
                val m = javaClass.getMethod("getPath")
                m.invoke(this) as? String
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun Intent.usbDevice(): UsbDevice? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
        } else {
            @Suppress("DEPRECATION")
            getParcelableExtra(UsbManager.EXTRA_DEVICE)
        }

    companion object {
        private const val TAG = "MuseUsbOtg"
        const val ACTION_USB_PERMISSION =
            "dev.musecompanion.muse_companion.USB_PERMISSION"
        private const val MAX_READ_BYTES = 10 * 1024 * 1024
        private const val MAX_LIST_ENTRIES = 500
    }
}
