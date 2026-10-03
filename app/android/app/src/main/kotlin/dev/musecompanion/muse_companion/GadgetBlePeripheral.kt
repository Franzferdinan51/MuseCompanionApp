package dev.musecompanion.muse_companion

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.ParcelUuid
import android.util.Log
import java.util.UUID

/**
 * BLE peripheral for Muse gadget setup, mirroring the reference firmware
 * (esp32/main/ble_server.c) and BlueZ server (linux ble_server.py).
 *
 * Advertising packet: flags + complete 128-bit service UUID + manufacturer
 * data (company 0xFFFF + 1 byte paired flag). Scan response: the complete
 * local name (MuseGadgetXXXXXX). GATT: RX (write) + TX (read, notify).
 *
 * One setup client at a time: advertising stops while connected and resumes
 * on disconnect until [stop] is called.
 */
class GadgetBlePeripheral(
    private val context: Context,
    private val listener: Listener,
) {
    interface Listener {
        fun onWrite(data: ByteArray, mtu: Int)
        fun onConnected()
        fun onDisconnected()
        fun onMtu(mtu: Int)
        fun onError(message: String)
    }

    companion object {
        private const val TAG = "GadgetBle"
        private const val CCCD_UUID = "00002902-0000-1000-8000-00805f9b34fb"
        private const val PAIRED_FLAG_COMPANY_ID = 0xFFFF
        private const val PREFS = "gadget_ble"
        private const val KEY_ORIGINAL_NAME = "original_adapter_name"
        private const val KEY_NAME_OVERRIDDEN = "adapter_name_overridden"
        const val DEFAULT_MTU = 23
    }

    private val bluetoothManager: BluetoothManager? =
        context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    private val adapter: BluetoothAdapter? get() = bluetoothManager?.adapter

    private var gattServer: BluetoothGattServer? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private var advertiseCallback: AdvertiseCallback? = null
    private var txCharacteristic: BluetoothGattCharacteristic? = null
    private var connectedDevice: BluetoothDevice? = null
    private var currentMtu: Int = DEFAULT_MTU
    private var running: Boolean = false
    private var lastDeviceName: String = ""
    private var lastPaired: Boolean = false
    private var lastServiceUuid: UUID? = null
    private val preparedWrites = mutableMapOf<String, java.io.ByteArrayOutputStream>()

    fun isSupported(): Boolean {
        if (!context.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)) {
            return false
        }
        val adapter = adapter ?: return false
        if (!adapter.isEnabled) return false
        if (!adapter.isMultipleAdvertisementSupported) return false
        return adapter.bluetoothLeAdvertiser != null
    }

    fun isBluetoothOn(): Boolean = adapter?.isEnabled == true

    /**
     * Start the GATT server and advertising.
     *
     * [paired] selects the paired-flag byte in the manufacturer data. The
     * adapter name is pointed at [deviceName] while running (the Muse app
     * reads the GAP name too) and restored on [stop].
     */
    @SuppressLint("MissingPermission")
    fun start(
        deviceName: String,
        paired: Boolean,
        serviceUuid: UUID,
        rxUuid: UUID,
        txUuid: UUID,
    ): Boolean {
        if (running) return true
        val adapter = adapter
        if (adapter == null || !adapter.isEnabled) {
            listener.onError("bluetooth is off")
            return false
        }
        if (!adapter.isMultipleAdvertisementSupported) {
            listener.onError("BLE advertising is not supported on this device")
            return false
        }
        lastDeviceName = deviceName
        lastPaired = paired
        lastServiceUuid = serviceUuid
        currentMtu = DEFAULT_MTU

        // Point the adapter (GAP) name at the gadget name; restored on stop.
        // The scan response carries this name, so advertising must not
        // start until the stack reads it back: on some devices setName
        // lands after startAdvertising and the name never goes on air.
        stashAdapterName(adapter)
        val setOk = try {
            adapter.setName(deviceName)
        } catch (e: SecurityException) {
            Log.w(TAG, "cannot set adapter name: ${e.message}")
            false
        }
        if (!setOk) {
            Log.w(TAG, "adapter setName returned false")
        }
        if (!awaitAdapterName(adapter, deviceName)) {
            Log.w(TAG, "adapter name did not read back as $deviceName; " +
                "scan response may miss the name")
        }

        if (!openGattServer(serviceUuid, rxUuid, txUuid)) {
            restoreAdapterName(adapter)
            return false
        }
        if (!startAdvertising(deviceName, paired, serviceUuid)) {
            closeGattServer()
            restoreAdapterName(adapter)
            return false
        }
        running = true
        Log.i(TAG, "advertising as $deviceName (paired=$paired)")
        return true
    }

    @SuppressLint("MissingPermission")
    fun stop() {
        running = false
        stopAdvertising()
        disconnect()
        closeGattServer()
        adapter?.let { restoreAdapterName(it) }
        connectedDevice = null
        currentMtu = DEFAULT_MTU
    }

    fun isAdvertising(): Boolean = running

    fun currentMtu(): Int = currentMtu

    /** Notify one packet on TX to the connected client, if any. */
    @SuppressLint("MissingPermission")
    fun notify(packet: ByteArray): Boolean {
        val server = gattServer ?: return false
        val device = connectedDevice ?: return false
        val tx = txCharacteristic ?: return false
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                server.notifyCharacteristicChanged(device, tx, false, packet)
            } else {
                @Suppress("DEPRECATION")
                tx.value = packet
                @Suppress("DEPRECATION")
                server.notifyCharacteristicChanged(device, tx, false)
            }
            true
        } catch (e: SecurityException) {
            Log.w(TAG, "notify failed: ${e.message}")
            false
        }
    }

    /** Disconnect the setup client; advertising resumes if still running. */
    @SuppressLint("MissingPermission")
    fun disconnect() {
        val server = gattServer
        val device = connectedDevice
        if (server != null && device != null) {
            try {
                server.cancelConnection(device)
            } catch (e: SecurityException) {
                Log.w(TAG, "cancelConnection failed: ${e.message}")
            }
        }
    }

    // -- GATT server ------------------------------------------------------

    @SuppressLint("MissingPermission")
    private fun openGattServer(
        serviceUuid: UUID,
        rxUuid: UUID,
        txUuid: UUID,
    ): Boolean {
        val manager = bluetoothManager ?: return false
        try {
            val server = manager.openGattServer(context, serverCallback)
                ?: return false
            val service = BluetoothGattService(
                serviceUuid, BluetoothGattService.SERVICE_TYPE_PRIMARY)

            val rx = BluetoothGattCharacteristic(
                rxUuid,
                BluetoothGattCharacteristic.PROPERTY_WRITE or
                    BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
                BluetoothGattCharacteristic.PERMISSION_WRITE,
            )
            val tx = BluetoothGattCharacteristic(
                txUuid,
                BluetoothGattCharacteristic.PROPERTY_READ or
                    BluetoothGattCharacteristic.PROPERTY_NOTIFY,
                BluetoothGattCharacteristic.PERMISSION_READ,
            )
            val cccd = BluetoothGattDescriptor(
                UUID.fromString(CCCD_UUID),
                BluetoothGattDescriptor.PERMISSION_READ or
                    BluetoothGattDescriptor.PERMISSION_WRITE,
            )
            tx.addDescriptor(cccd)
            service.addCharacteristic(rx)
            service.addCharacteristic(tx)
            if (!server.addService(service)) {
                server.close()
                listener.onError("failed to add the setup GATT service")
                return false
            }
            gattServer = server
            txCharacteristic = tx
            return true
        } catch (e: SecurityException) {
            listener.onError("bluetooth permission denied: ${e.message}")
            return false
        }
    }

    private fun closeGattServer() {
        try {
            gattServer?.close()
        } catch (e: SecurityException) {
            Log.w(TAG, "gatt close failed: ${e.message}")
        }
        gattServer = null
        txCharacteristic = null
    }

    private val serverCallback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(
            device: BluetoothDevice?,
            status: Int,
            newState: Int,
        ) {
            if (newState == BluetoothGattServer.STATE_CONNECTED) {
                connectedDevice = device
                currentMtu = DEFAULT_MTU
                stopAdvertising()
                listener.onConnected()
                Log.i(TAG, "client connected")
            } else if (newState == BluetoothGattServer.STATE_DISCONNECTED) {
                connectedDevice = null
                currentMtu = DEFAULT_MTU
                preparedWrites.clear()
                listener.onDisconnected()
                Log.i(TAG, "client disconnected")
                // Resume advertising for the next attempt, like the
                // firmware does.
                if (running) {
                    val uuid = lastServiceUuid
                    if (uuid != null) {
                        startAdvertising(lastDeviceName, lastPaired, uuid)
                    }
                }
            }
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice?,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic?,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray?,
        ) {
            if (responseNeeded) {
                try {
                    gattServer?.sendResponse(
                        device, requestId,
                        android.bluetooth.BluetoothGatt.GATT_SUCCESS, offset, null)
                } catch (e: SecurityException) {
                    Log.w(TAG, "write response failed: ${e.message}")
                }
            }
            if (value == null) return
            if (!preparedWrite) {
                listener.onWrite(value, currentMtu)
                return
            }
            // Long write: queue the part; onExecuteWrite delivers the whole.
            val key = device?.address ?: "unknown"
            val queue = preparedWrites.getOrPut(key) {
                java.io.ByteArrayOutputStream()
            }
            if (offset != queue.size()) {
                Log.w(TAG, "prepared write offset $offset != queued ${queue.size()}; restarting")
                queue.reset()
            }
            try {
                queue.write(value)
            } catch (e: java.io.IOException) {
                Log.w(TAG, "prepared write queue failed: ${e.message}")
                preparedWrites.remove(key)
            }
        }

        override fun onExecuteWrite(
            device: BluetoothDevice?,
            requestId: Int,
            execute: Boolean,
        ) {
            val key = device?.address ?: "unknown"
            val queued = preparedWrites.remove(key)
            try {
                gattServer?.sendResponse(
                    device, requestId,
                    android.bluetooth.BluetoothGatt.GATT_SUCCESS, 0, null)
            } catch (e: SecurityException) {
                Log.w(TAG, "execute response failed: ${e.message}")
            }
            if (execute && queued != null && queued.size() > 0) {
                Log.i(TAG, "delivering long write (${queued.size()} bytes)")
                listener.onWrite(queued.toByteArray(), currentMtu)
            }
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice?,
            requestId: Int,
            descriptor: BluetoothGattDescriptor?,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray?,
        ) {
            if (responseNeeded) {
                try {
                    gattServer?.sendResponse(
                        device, requestId,
                        android.bluetooth.BluetoothGatt.GATT_SUCCESS, offset, null)
                } catch (e: SecurityException) {
                    Log.w(TAG, "descriptor response failed: ${e.message}")
                }
            }
            Log.i(TAG, "client subscribed: ${value?.contentToString()}")
        }

        override fun onCharacteristicReadRequest(
            device: BluetoothDevice?,
            requestId: Int,
            offset: Int,
            characteristic: BluetoothGattCharacteristic?,
        ) {
            // TX read returns the last notified value (often empty); the
            // setup flow uses notifications.
            try {
                gattServer?.sendResponse(
                    device, requestId,
                    android.bluetooth.BluetoothGatt.GATT_SUCCESS, offset,
                    characteristic?.value)
            } catch (e: SecurityException) {
                Log.w(TAG, "read response failed: ${e.message}")
            }
        }

        override fun onMtuChanged(device: BluetoothDevice?, mtu: Int) {
            currentMtu = mtu
            listener.onMtu(mtu)
            Log.i(TAG, "MTU changed: $mtu")
        }
    }

    // -- Advertising --------------------------------------------------------

    @SuppressLint("MissingPermission")
    private fun startAdvertising(
        deviceName: String,
        paired: Boolean,
        serviceUuid: UUID,
    ): Boolean {
        val adapter = adapter ?: return false
        val advertiser = adapter.bluetoothLeAdvertiser ?: run {
            listener.onError("no BLE advertiser on this device")
            return false
        }
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .setConnectable(true)
            .build()
        // Adv packet mirrors the firmware: flags are added by the stack,
        // plus the complete service UUID and the paired-flag mfg data.
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .setIncludeTxPowerLevel(false)
            .addServiceUuid(ParcelUuid(serviceUuid))
            .addManufacturerData(
                PAIRED_FLAG_COMPANY_ID,
                byteArrayOf(if (paired) 0x01 else 0x00),
            )
            .build()
        // Scan response carries the complete local name (the adapter name
        // was pointed at the gadget name in start()).
        val scanResponse = AdvertiseData.Builder()
            .setIncludeDeviceName(true)
            .setIncludeTxPowerLevel(false)
            .build()
        val callback = object : AdvertiseCallback() {
            override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
                val readBack = try {
                    adapter.name
                } catch (e: SecurityException) {
                    null
                }
                Log.i(TAG, "advertising started " +
                    "(adapter name reads back as $readBack)")
            }

            override fun onStartFailure(errorCode: Int) {
                listener.onError("advertising failed (code $errorCode)")
            }
        }
        return try {
            advertiser.startAdvertising(settings, data, scanResponse, callback)
            this.advertiser = advertiser
            advertiseCallback = callback
            true
        } catch (e: SecurityException) {
            listener.onError("bluetooth permission denied: ${e.message}")
            false
        } catch (e: IllegalArgumentException) {
            listener.onError("advertising data too large: ${e.message}")
            false
        }
    }

    @SuppressLint("MissingPermission")
    private fun stopAdvertising() {
        val advertiser = advertiser
        val callback = advertiseCallback
        if (advertiser != null && callback != null) {
            try {
                advertiser.stopAdvertising(callback)
            } catch (e: SecurityException) {
                Log.w(TAG, "stopAdvertising failed: ${e.message}")
            }
        }
        this.advertiser = null
        advertiseCallback = null
    }

    // -- Adapter name stewardship --------------------------------------------

    /**
     * Wait until [adapter.name] reads back as [want], so a scan response
     * started right after carries it. Returns false on timeout; callers
     * advertise anyway (Muse-app discovery keys on the service UUID).
     */
    private fun awaitAdapterName(
        adapter: BluetoothAdapter,
        want: String,
    ): Boolean {
        repeat(10) {
            val current = try {
                adapter.name
            } catch (e: SecurityException) {
                null
            }
            if (current == want) {
                Log.i(TAG, "adapter name confirmed: $want")
                return true
            }
            try {
                Thread.sleep(100)
            } catch (e: InterruptedException) {
                Thread.currentThread().interrupt()
                return false
            }
        }
        val last = try {
            adapter.name
        } catch (e: SecurityException) {
            null
        }
        Log.w(TAG, "adapter name reads back as $last, want $want")
        return false
    }

    private fun stashAdapterName(adapter: BluetoothAdapter) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        // Restore a name left behind by an unclean stop first.
        if (prefs.getBoolean(KEY_NAME_OVERRIDDEN, false)) {
            prefs.getString(KEY_ORIGINAL_NAME, null)?.let { original ->
                try {
                    adapter.name = original
                } catch (e: SecurityException) {
                    Log.w(TAG, "stale adapter name restore failed: ${e.message}")
                }
            }
        }
        val current = try {
            adapter.name
        } catch (e: SecurityException) {
            null
        }
        prefs.edit()
            .putString(KEY_ORIGINAL_NAME, current)
            .putBoolean(KEY_NAME_OVERRIDDEN, true)
            .apply()
    }

    private fun restoreAdapterName(adapter: BluetoothAdapter) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (!prefs.getBoolean(KEY_NAME_OVERRIDDEN, false)) return
        prefs.getString(KEY_ORIGINAL_NAME, null)?.let { original ->
            try {
                adapter.name = original
            } catch (e: SecurityException) {
                Log.w(TAG, "adapter name restore failed: ${e.message}")
            }
        }
        prefs.edit().putBoolean(KEY_NAME_OVERRIDDEN, false).apply()
    }
}
