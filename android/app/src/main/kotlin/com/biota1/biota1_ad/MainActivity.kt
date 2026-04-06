package com.biota1.biota1_ad

import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.biota1.biota1_ad/ble_write"
    private val gattCache = mutableMapOf<String, BluetoothGatt>()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "forceWrite") {
                    val remoteId = call.argument<String>("remoteId")
                    val serviceUuid = call.argument<String>("serviceUuid")
                    val charUuid = call.argument<String>("charUuid")
                    val value = call.argument<ByteArray>("value")
                    val noResponse = call.argument<Boolean>("noResponse") ?: true

                    if (remoteId == null || serviceUuid == null || charUuid == null || value == null) {
                        result.error("INVALID_ARGS", "Missing arguments", null)
                        return@setMethodCallHandler
                    }

                    Thread {
                        try {
                            val success = forceWrite(remoteId, serviceUuid, charUuid, value, noResponse)
                            Handler(Looper.getMainLooper()).post {
                                if (success) result.success(true)
                                else result.error("WRITE_FAILED", "Write returned false", null)
                            }
                        } catch (e: Exception) {
                            Handler(Looper.getMainLooper()).post {
                                result.error("WRITE_ERROR", e.message ?: "Unknown error", null)
                            }
                        }
                    }.start()
                } else {
                    result.notImplemented()
                }
            }
    }

    @Suppress("DEPRECATION", "MissingPermission")
    private fun forceWrite(
        remoteId: String,
        serviceUuid: String,
        charUuid: String,
        value: ByteArray,
        noResponse: Boolean
    ): Boolean {
        val bluetoothManager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        val adapter = bluetoothManager.adapter ?: throw Exception("No Bluetooth adapter")
        val device = adapter.getRemoteDevice(remoteId)

        // Try cached GATT first
        var gatt = gattCache[remoteId]
        if (gatt != null) {
            val svc = gatt.getService(UUID.fromString(serviceUuid))
            if (svc != null) {
                val result = writeToGatt(gatt, serviceUuid, charUuid, value, noResponse)
                if (result) return true
            }
            // Cached GATT stale, remove it
            try { gatt.close() } catch (_: Exception) {}
            gattCache.remove(remoteId)
        }

        // Connect to get a GATT handle (Android shares the underlying connection
        // if flutter_blue_plus already has one)
        android.util.Log.d("BleForceWrite", "Connecting to $remoteId for write")
        val latch = CountDownLatch(1)
        var connectedGatt: BluetoothGatt? = null

        val callback = object : BluetoothGattCallback() {
            override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    g.discoverServices()
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    latch.countDown()
                }
            }
            override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    connectedGatt = g
                }
                latch.countDown()
            }
        }

        device.connectGatt(this, false, callback, android.bluetooth.BluetoothDevice.TRANSPORT_LE)

        if (!latch.await(15, TimeUnit.SECONDS)) {
            throw Exception("Timed out waiting for GATT services")
        }

        gatt = connectedGatt ?: throw Exception("Failed to discover services on $remoteId")
        gattCache[remoteId] = gatt

        return writeToGatt(gatt, serviceUuid, charUuid, value, noResponse)
    }

    @Suppress("DEPRECATION")
    private fun writeToGatt(
        gatt: BluetoothGatt,
        serviceUuid: String,
        charUuid: String,
        value: ByteArray,
        noResponse: Boolean
    ): Boolean {
        val service = gatt.getService(UUID.fromString(serviceUuid))
            ?: throw Exception("Service $serviceUuid not found")
        val characteristic = service.getCharacteristic(UUID.fromString(charUuid))
            ?: throw Exception("Characteristic $charUuid not found")

        // Try both write types — no property check
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val type1 = if (noResponse)
                BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
            else
                BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
            val type2 = if (noResponse)
                BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
            else
                BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE

            var rv = gatt.writeCharacteristic(characteristic, value, type1)
            if (rv != BluetoothGatt.GATT_SUCCESS) {
                rv = gatt.writeCharacteristic(characteristic, value, type2)
            }
            return rv == BluetoothGatt.GATT_SUCCESS
        } else {
            characteristic.value = value

            characteristic.writeType = if (noResponse)
                BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
            else
                BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
            var success = gatt.writeCharacteristic(characteristic)

            if (!success) {
                characteristic.writeType = if (noResponse)
                    BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                else
                    BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
                success = gatt.writeCharacteristic(characteristic)
            }
            return success
        }
    }

    override fun onDestroy() {
        gattCache.values.forEach {
            try { it.close() } catch (_: Exception) {}
        }
        gattCache.clear()
        super.onDestroy()
    }
}
