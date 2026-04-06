import Flutter
import UIKit
import CoreBluetooth

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var bleWriter: BleForceWriter?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    // Set up native BLE write channel
    let controller = window?.rootViewController as! FlutterViewController
    let channel = FlutterMethodChannel(
      name: "com.biota1.biota1_ad/ble_write",
      binaryMessenger: controller.binaryMessenger
    )

    bleWriter = BleForceWriter()

    channel.setMethodCallHandler { [weak self] (call, result) in
      guard call.method == "forceWrite" else {
        result(FlutterMethodNotImplemented)
        return
      }

      guard let args = call.arguments as? [String: Any],
            let remoteId = args["remoteId"] as? String,
            let serviceUuid = args["serviceUuid"] as? String,
            let charUuid = args["charUuid"] as? String,
            let value = args["value"] as? FlutterStandardTypedData else {
        result(FlutterError(code: "INVALID_ARGS", message: "Missing arguments", details: nil))
        return
      }

      let noResponse = args["noResponse"] as? Bool ?? true

      self?.bleWriter?.forceWrite(
        remoteId: remoteId,
        serviceUuid: serviceUuid,
        charUuid: charUuid,
        value: value.data,
        noResponse: noResponse,
        result: result
      )
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

/// Handles BLE write operations bypassing flutter_blue_plus property checks.
/// Connects directly via CoreBluetooth and writes to the characteristic.
class BleForceWriter: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
  private var centralManager: CBCentralManager?
  private var pendingResult: FlutterResult?
  private var pendingValue: Data?
  private var pendingCharUuid: CBUUID?
  private var pendingServiceUuid: CBUUID?
  private var pendingNoResponse: Bool = true
  private var connectedPeripherals: [String: CBPeripheral] = [:]
  private var discoveredPeripherals: [String: CBPeripheral] = [:]

  override init() {
    super.init()
    centralManager = CBCentralManager(delegate: self, queue: nil, options: [
      CBCentralManagerOptionShowPowerAlertKey: false
    ])
  }

  func forceWrite(
    remoteId: String,
    serviceUuid: String,
    charUuid: String,
    value: Data,
    noResponse: Bool,
    result: @escaping FlutterResult
  ) {
    guard let cm = centralManager, cm.state == .poweredOn else {
      result(FlutterError(code: "BT_OFF", message: "Bluetooth is not powered on", details: nil))
      return
    }

    let svcUuid = CBUUID(string: serviceUuid)
    let chrUuid = CBUUID(string: charUuid)

    // Check if we already have a connected peripheral with discovered services
    if let peripheral = connectedPeripherals[remoteId.uppercased()],
       peripheral.state == .connected {
      writeToPeripheral(peripheral, serviceUuid: svcUuid, charUuid: chrUuid, value: value, noResponse: noResponse, result: result)
      return
    }

    // Try to find the peripheral from CoreBluetooth's connected peripherals
    let connected = cm.retrieveConnectedPeripherals(withServices: [svcUuid])
    if let peripheral = connected.first(where: {
      $0.identifier.uuidString.uppercased() == remoteId.uppercased() ||
      formatAsColonSeparated($0.identifier.uuidString).uppercased() == remoteId.uppercased()
    }) {
      peripheral.delegate = self
      connectedPeripherals[remoteId.uppercased()] = peripheral

      // Store pending write info
      pendingResult = result
      pendingValue = value
      pendingCharUuid = chrUuid
      pendingServiceUuid = svcUuid
      pendingNoResponse = noResponse

      if peripheral.state == .connected {
        peripheral.discoverServices([svcUuid])
      } else {
        cm.connect(peripheral, options: nil)
      }
      return
    }

    // Try retrievePeripherals by UUID
    if let uuid = UUID(uuidString: remoteId) {
      let peripherals = cm.retrievePeripherals(withIdentifiers: [uuid])
      if let peripheral = peripherals.first {
        peripheral.delegate = self
        connectedPeripherals[remoteId.uppercased()] = peripheral

        pendingResult = result
        pendingValue = value
        pendingCharUuid = chrUuid
        pendingServiceUuid = svcUuid
        pendingNoResponse = noResponse

        if peripheral.state == .connected {
          peripheral.discoverServices([svcUuid])
        } else {
          cm.connect(peripheral, options: nil)
        }
        return
      }
    }

    // Try matching by scanning connected peripherals for all known BLE services
    let allServiceUuids = [
      CBUUID(string: "0000181c-0000-1000-8000-00805f9b34fb"),
      CBUUID(string: "0000180a-0000-1000-8000-00805f9b34fb"),
      CBUUID(string: "0000180f-0000-1000-8000-00805f9b34fb"),
    ]
    let allConnected = cm.retrieveConnectedPeripherals(withServices: allServiceUuids)
    if let peripheral = allConnected.first {
      peripheral.delegate = self
      connectedPeripherals[remoteId.uppercased()] = peripheral

      pendingResult = result
      pendingValue = value
      pendingCharUuid = chrUuid
      pendingServiceUuid = svcUuid
      pendingNoResponse = noResponse

      if peripheral.state == .connected {
        peripheral.discoverServices([svcUuid])
      } else {
        cm.connect(peripheral, options: nil)
      }
      return
    }

    result(FlutterError(code: "NO_DEVICE", message: "Could not find peripheral \(remoteId)", details: nil))
  }

  private func writeToPeripheral(
    _ peripheral: CBPeripheral,
    serviceUuid: CBUUID,
    charUuid: CBUUID,
    value: Data,
    noResponse: Bool,
    result: @escaping FlutterResult
  ) {
    guard let service = peripheral.services?.first(where: { $0.uuid == serviceUuid }) else {
      // Need to discover services first
      pendingResult = result
      pendingValue = value
      pendingCharUuid = charUuid
      pendingServiceUuid = serviceUuid
      pendingNoResponse = noResponse
      peripheral.discoverServices([serviceUuid])
      return
    }

    guard let characteristic = service.characteristics?.first(where: { $0.uuid == charUuid }) else {
      // Need to discover characteristics
      pendingResult = result
      pendingValue = value
      pendingCharUuid = charUuid
      pendingServiceUuid = serviceUuid
      pendingNoResponse = noResponse
      peripheral.discoverCharacteristics([charUuid], for: service)
      return
    }

    let writeType: CBCharacteristicWriteType = noResponse ? .withoutResponse : .withResponse
    peripheral.writeValue(value, for: characteristic, type: writeType)

    if noResponse {
      // writeWithoutResponse doesn't trigger a delegate callback
      result(true)
    } else {
      pendingResult = result
    }
  }

  private func formatAsColonSeparated(_ uuid: String) -> String {
    // Convert UUID format to MAC-like format if needed
    return uuid
  }

  // MARK: - CBCentralManagerDelegate

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    // Required delegate method
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    if let svcUuid = pendingServiceUuid {
      peripheral.discoverServices([svcUuid])
    }
  }

  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    pendingResult?(FlutterError(code: "CONNECT_FAILED", message: error?.localizedDescription ?? "Connection failed", details: nil))
    pendingResult = nil
  }

  // MARK: - CBPeripheralDelegate

  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    if let error = error {
      pendingResult?(FlutterError(code: "SERVICE_ERROR", message: error.localizedDescription, details: nil))
      pendingResult = nil
      return
    }

    guard let svcUuid = pendingServiceUuid,
          let service = peripheral.services?.first(where: { $0.uuid == svcUuid }),
          let charUuid = pendingCharUuid else {
      pendingResult?(FlutterError(code: "NO_SERVICE", message: "Service not found", details: nil))
      pendingResult = nil
      return
    }

    peripheral.discoverCharacteristics([charUuid], for: service)
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    if let error = error {
      pendingResult?(FlutterError(code: "CHAR_ERROR", message: error.localizedDescription, details: nil))
      pendingResult = nil
      return
    }

    guard let charUuid = pendingCharUuid,
          let characteristic = service.characteristics?.first(where: { $0.uuid == charUuid }),
          let value = pendingValue,
          let result = pendingResult else {
      pendingResult?(FlutterError(code: "NO_CHAR", message: "Characteristic not found", details: nil))
      pendingResult = nil
      return
    }

    let writeType: CBCharacteristicWriteType = pendingNoResponse ? .withoutResponse : .withResponse
    peripheral.writeValue(value, for: characteristic, type: writeType)

    if pendingNoResponse {
      result(true)
      pendingResult = nil
    }
    // For withResponse, wait for didWriteValueFor callback
  }

  func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
    if let error = error {
      pendingResult?(FlutterError(code: "WRITE_ERROR", message: error.localizedDescription, details: nil))
    } else {
      pendingResult?(true)
    }
    pendingResult = nil
  }
}
