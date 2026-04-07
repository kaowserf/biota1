import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

const _kBleWriteChannel = MethodChannel('com.biota1.biota1_ad/ble_write');

class BluetoothBridge {
  final List<ScanResult> _scanResults = [];
  StreamSubscription<List<ScanResult>>? _scanSub;
  BluetoothDevice? _connectedDevice;
  final Map<String, BluetoothCharacteristic> _characteristics = {};
  final List<StreamSubscription<List<int>>> _notifySubs = [];

  final void Function(String method, String data) onResultReady;

  BluetoothBridge({required this.onResultReady});

  /// Request Bluetooth & location permissions needed for BLE scanning.
  Future<bool> requestPermissions() async {
    // iOS does not use runtime permission_handler permissions for BLE scan/
    // connect — the system prompts automatically on first BLE use based on
    // Info.plist's NSBluetoothAlwaysUsageDescription. Returning true here lets
    // FlutterBluePlus trigger that native prompt.
    if (Platform.isIOS) {
      return true;
    }

    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    return statuses.values.every(
      (s) => s.isGranted || s.isLimited,
    );
  }

  /// Check if Bluetooth adapter is on.
  Future<bool> isBluetoothOn() async {
    final state = await FlutterBluePlus.adapterState.first;
    return state == BluetoothAdapterState.on;
  }

  /// Start scanning for BLE devices whose name contains [nameFilter].
  /// Returns scan results as JSON to the web page periodically.
  Future<void> startScan({String? nameFilter, int timeoutSeconds = 15}) async {
    final hasPermission = await requestPermissions();
    if (!hasPermission) {
      onResultReady('onScanError', jsonEncode({
        'error': 'Bluetooth permissions not granted. Please enable them in Settings.',
      }));
      return;
    }

    final btOn = await isBluetoothOn();
    if (!btOn) {
      onResultReady('onScanError', jsonEncode({
        'error': 'Bluetooth is turned off. Please enable Bluetooth.',
      }));
      return;
    }

    _scanResults.clear();

    _scanSub = FlutterBluePlus.onScanResults.listen((results) {
      for (final r in results) {
        final exists = _scanResults.any(
          (e) => e.device.remoteId == r.device.remoteId,
        );
        if (!exists) {
          final name = r.device.platformName;
          if (nameFilter == null ||
              nameFilter.isEmpty ||
              name.toLowerCase().contains(nameFilter.toLowerCase())) {
            _scanResults.add(r);
          }
        }
      }
      // Send updated device list to web page
      _sendDeviceList();
    });

    await FlutterBluePlus.startScan(
      timeout: Duration(seconds: timeoutSeconds),
    );

    // Scanning finished
    onResultReady('onScanComplete', jsonEncode({'count': _scanResults.length}));
  }

  void _sendDeviceList() {
    final devices = _scanResults.map((r) => {
      'id': r.device.remoteId.str,
      'name': r.device.platformName.isNotEmpty
          ? r.device.platformName
          : 'Unknown',
      'rssi': r.rssi,
    }).toList();

    onResultReady('onDevicesFound', jsonEncode(devices));
  }

  /// Stop an active scan.
  Future<void> stopScan() async {
    await FlutterBluePlus.stopScan();
    _scanSub?.cancel();
    _scanSub = null;
  }

  /// Connect to a device by its remote ID string.
  Future<void> connectToDevice(String deviceId) async {
    try {
      await stopScan();

      final device = BluetoothDevice.fromId(deviceId);
      await device.connect(timeout: const Duration(seconds: 15));
      _connectedDevice = device;

      // Discover services
      final services = await device.discoverServices();
      final serviceList = <Map<String, dynamic>>[];

      for (final service in services) {
        final chars = <Map<String, String>>[];
        for (final c in service.characteristics) {
          // Store every characteristic by UUID for later lookup
          _characteristics[c.uuid.str.toLowerCase()] = c;

          final props = _charPropsToString(c.properties);
          debugPrint('BLE char: ${service.uuid.str} / ${c.uuid.str} [$props]');

          chars.add({
            'uuid': c.uuid.str,
            'properties': props,
          });

          // Auto-subscribe to notify/indicate characteristics
          if (c.properties.notify || c.properties.indicate) {
            try {
              await c.setNotifyValue(true);
              _notifySubs.add(c.onValueReceived.listen((value) {
                onResultReady('onBleData', jsonEncode({
                  'characteristicUuid': c.uuid.str,
                  'value': base64Encode(value),
                }));
              }));
            } catch (e) {
              debugPrint('Failed to subscribe to ${c.uuid.str}: $e');
            }
          }
        }
        serviceList.add({
          'uuid': service.uuid.str,
          'characteristics': chars,
        });
      }

      onResultReady('onConnected', jsonEncode({
        'deviceId': deviceId,
        'deviceName': device.platformName,
        'services': serviceList,
      }));
    } catch (e) {
      onResultReady('onConnectError', jsonEncode({
        'error': e.toString(),
        'deviceId': deviceId,
      }));
    }
  }

  /// Write data to a characteristic on the connected device.
  Future<void> writeData(String base64Data, {String? charUuid}) async {
    if (_connectedDevice == null) {
      onResultReady('onWriteError', jsonEncode({
        'error': 'No connected device.',
      }));
      return;
    }

    final bytes = base64Decode(base64Data);

    // Resolve which characteristic to write to
    BluetoothCharacteristic? target;
    if (charUuid != null && charUuid.isNotEmpty) {
      target = _characteristics[charUuid.toLowerCase()];
    }
    // Fallback: first writable characteristic
    target ??= _characteristics.values
        .cast<BluetoothCharacteristic?>()
        .firstWhere(
          (c) => c!.properties.write || c.properties.writeWithoutResponse,
          orElse: () => null,
        );

    // Try flutter_blue_plus write first (if characteristic is writable)
    if (target != null &&
        (target.properties.write || target.properties.writeWithoutResponse)) {
      try {
        final preferNoResponse = target.properties.writeWithoutResponse;
        try {
          await target.write(bytes, withoutResponse: preferNoResponse);
        } catch (_) {
          await target.write(bytes, withoutResponse: !preferNoResponse);
        }
        onResultReady('onWriteSuccess', jsonEncode({'bytes': bytes.length}));
        return;
      } catch (e) {
        debugPrint('BLE write via flutter_blue_plus failed: $e');
      }
    }

    // Fallback: native platform channel write (bypasses property checks)
    debugPrint('BLE write: using native forceWrite fallback');
    try {
      String? writeServiceUuid;
      String? writeCharUuid;

      // 1. Use target's own service/char UUIDs if available
      if (target != null) {
        writeServiceUuid = _toFullUuid(target.serviceUuid.str);
        writeCharUuid = _toFullUuid(target.uuid.str);
      }

      // 2. Look up charUuid in the map
      if (writeCharUuid == null && charUuid != null) {
        final key = charUuid.toLowerCase();
        for (final entry in _characteristics.entries) {
          final entryFull = _toFullUuid(entry.value.uuid.str);
          if (entry.key == key || entryFull == _toFullUuid(charUuid)) {
            writeCharUuid = entryFull;
            writeServiceUuid = _toFullUuid(entry.value.serviceUuid.str);
            break;
          }
        }
      }

      // 3. Last resort: use known Hearit.AI command characteristic
      writeServiceUuid ??= '0000181c-0000-1000-8000-00805f9b34fb';
      writeCharUuid ??= '00002b7a-0000-1000-8000-00805f9b34fb';

      debugPrint('BLE forceWrite: service=$writeServiceUuid char=$writeCharUuid');

      await _kBleWriteChannel.invokeMethod('forceWrite', {
        'remoteId': _connectedDevice!.remoteId.str,
        'serviceUuid': writeServiceUuid,
        'charUuid': writeCharUuid,
        'value': Uint8List.fromList(bytes),
        'noResponse': true,
      });
      onResultReady('onWriteSuccess', jsonEncode({'bytes': bytes.length}));
    } catch (e) {
      debugPrint('BLE native forceWrite also failed: $e');
      onResultReady('onWriteError', jsonEncode({'error': e.toString()}));
    }
  }

  /// Expand a short BLE UUID to full 128-bit format.
  static String _toFullUuid(String uuid) {
    final s = uuid.toLowerCase().replaceAll('-', '');
    if (s.length <= 8 && RegExp(r'^[0-9a-f]+$').hasMatch(s)) {
      final padded = s.padLeft(8, '0');
      return '$padded-0000-1000-8000-00805f9b34fb';
    }
    return uuid;
  }

  /// Disconnect from the current device.
  Future<void> disconnect() async {
    for (final sub in _notifySubs) {
      sub.cancel();
    }
    _notifySubs.clear();
    _characteristics.clear();

    if (_connectedDevice != null) {
      await _connectedDevice!.disconnect();
      _connectedDevice = null;
    }

    onResultReady('onDisconnected', jsonEncode({'success': true}));
  }

  /// Show a native device picker dialog.
  Future<void> showDevicePicker(BuildContext context, {String? nameFilter}) async {
    final hasPermission = await requestPermissions();
    if (!hasPermission) {
      onResultReady('onScanError', jsonEncode({
        'error': 'Bluetooth permissions not granted.',
      }));
      return;
    }

    final btOn = await isBluetoothOn();
    if (!btOn) {
      onResultReady('onScanError', jsonEncode({
        'error': 'Bluetooth is turned off. Please enable Bluetooth.',
      }));
      return;
    }

    _scanResults.clear();

    if (!context.mounted) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1a2a3f),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _DevicePickerSheet(
        nameFilter: nameFilter,
        onDeviceSelected: (deviceId) {
          Navigator.of(ctx).pop();
          connectToDevice(deviceId);
        },
        onCancel: () {
          Navigator.of(ctx).pop();
          stopScan();
          onResultReady('onScanCancelled', jsonEncode({'cancelled': true}));
        },
      ),
    );
  }

  String _charPropsToString(CharacteristicProperties p) {
    final parts = <String>[];
    if (p.read) parts.add('read');
    if (p.write) parts.add('write');
    if (p.writeWithoutResponse) parts.add('writeWithoutResponse');
    if (p.notify) parts.add('notify');
    if (p.indicate) parts.add('indicate');
    return parts.join(',');
  }

  void dispose() {
    stopScan();
    for (final sub in _notifySubs) {
      sub.cancel();
    }
    _connectedDevice?.disconnect();
  }
}

/// Bottom sheet that shows scanned BLE devices in a native-looking picker.
class _DevicePickerSheet extends StatefulWidget {
  final String? nameFilter;
  final void Function(String deviceId) onDeviceSelected;
  final VoidCallback onCancel;

  const _DevicePickerSheet({
    this.nameFilter,
    required this.onDeviceSelected,
    required this.onCancel,
  });

  @override
  State<_DevicePickerSheet> createState() => _DevicePickerSheetState();
}

class _DevicePickerSheetState extends State<_DevicePickerSheet> {
  final List<ScanResult> _devices = [];
  StreamSubscription<List<ScanResult>>? _sub;
  bool _scanning = true;

  @override
  void initState() {
    super.initState();
    _startScan();
  }

  Future<void> _startScan() async {
    _sub = FlutterBluePlus.onScanResults.listen((results) {
      for (final r in results) {
        final exists = _devices.any(
          (e) => e.device.remoteId == r.device.remoteId,
        );
        if (!exists) {
          final name = r.device.platformName;
          if (widget.nameFilter == null ||
              widget.nameFilter!.isEmpty ||
              name.toLowerCase().contains(widget.nameFilter!.toLowerCase())) {
            if (mounted) setState(() => _devices.add(r));
          }
        }
      }
    });

    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));
    if (mounted) setState(() => _scanning = false);
  }

  @override
  void dispose() {
    _sub?.cancel();
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Icon(Icons.bluetooth, color: Color(0xFF00b4d8), size: 24),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Select Your Clip',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
              TextButton(
                onPressed: widget.onCancel,
                child: const Text(
                  'Cancel',
                  style: TextStyle(color: Color(0xFF00b4d8)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Looking for nearby Bluetooth devices...',
            style: TextStyle(fontSize: 13, color: Colors.white54),
          ),
          const SizedBox(height: 12),
          if (_scanning)
            const LinearProgressIndicator(
              color: Color(0xFF00b4d8),
              backgroundColor: Color(0xFF0a1628),
            ),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.35,
            ),
            child: _devices.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        _scanning
                            ? 'Scanning for devices...'
                            : 'No devices found. Make sure your Clip is on.',
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 14,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: _devices.length,
                    itemBuilder: (_, i) {
                      final device = _devices[i];
                      final name = device.device.platformName.isNotEmpty
                          ? device.device.platformName
                          : 'Unknown Device';
                      return ListTile(
                        leading: const Icon(
                          Icons.bluetooth_searching,
                          color: Color(0xFF00b4d8),
                        ),
                        title: Text(
                          name,
                          style: const TextStyle(color: Colors.white),
                        ),
                        subtitle: Text(
                          device.device.remoteId.str,
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 12,
                          ),
                        ),
                        trailing: Text(
                          '${device.rssi} dBm',
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 12,
                          ),
                        ),
                        onTap: () => widget.onDeviceSelected(
                          device.device.remoteId.str,
                        ),
                      );
                    },
                  ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
