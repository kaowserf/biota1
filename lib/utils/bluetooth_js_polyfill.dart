/// JavaScript that gets injected into the WebView to polyfill
/// navigator.bluetooth with a bridge to native Flutter BLE.
const String bluetoothJsPolyfill = r'''
(function() {
  // Only polyfill if Web Bluetooth is not natively available
  if (navigator.bluetooth && navigator.bluetooth.requestDevice) return;

  console.log('[Biota1] Injecting native Bluetooth bridge polyfill');

  // Pending promise resolvers keyed by request ID
  const _pending = {};
  let _requestId = 0;
  let _connectedDevice = null;
  let _disconnectListeners = [];
  let _characteristicListeners = {};

  function _nextId() {
    return 'bt_' + (++_requestId);
  }

  // Called from Flutter via controller.runJavaScript
  window._bluetoothBridgeCallback = function(method, dataJson) {
    const data = JSON.parse(dataJson);

    switch (method) {
      case 'onDevicesFound':
        // Update available devices for the picker
        if (window._btDevicesCallback) {
          window._btDevicesCallback(data);
        }
        break;

      case 'onConnected':
        if (_pending['connect']) {
          _disconnectListeners = [];
          _connectedDevice = {
            id: data.deviceId,
            name: data.deviceName,
            gatt: _createGattServer(data),
            addEventListener: function(event, callback) {
              if (event === 'gattserverdisconnected') {
                _disconnectListeners.push(callback);
              }
            },
            removeEventListener: function(event, callback) {
              if (event === 'gattserverdisconnected') {
                _disconnectListeners = _disconnectListeners.filter(
                  cb => cb !== callback
                );
              }
            },
            dispatchEvent: function(event) {
              if (event.type === 'gattserverdisconnected') {
                _disconnectListeners.forEach(cb => cb(event));
              }
            },
          };
          _pending['connect'].resolve(_connectedDevice);
          delete _pending['connect'];
        }
        break;

      case 'onConnectError':
        if (_pending['connect']) {
          _pending['connect'].reject(new DOMException(data.error, 'NetworkError'));
          delete _pending['connect'];
        }
        break;

      case 'onScanError':
        if (_pending['requestDevice']) {
          _pending['requestDevice'].reject(new DOMException(data.error, 'NotFoundError'));
          delete _pending['requestDevice'];
        }
        break;

      case 'onScanCancelled':
        if (_pending['requestDevice']) {
          _pending['requestDevice'].reject(new DOMException('User cancelled', 'NotFoundError'));
          delete _pending['requestDevice'];
        }
        break;

      case 'onDisconnected':
        _disconnectListeners.forEach(function(cb) {
          try { cb({ type: 'gattserverdisconnected', target: _connectedDevice }); }
          catch(e) { console.warn('[Biota1] Disconnect listener error:', e); }
        });
        _connectedDevice = null;
        _disconnectListeners = [];
        break;

      case 'onBleData':
        const charUuid = data.characteristicUuid;
        if (_characteristicListeners[charUuid]) {
          const bytes = Uint8Array.from(atob(data.value), c => c.charCodeAt(0));
          _characteristicListeners[charUuid].forEach(cb => {
            cb({ target: { value: new DataView(bytes.buffer) } });
          });
        }
        break;

      case 'onWriteSuccess':
        if (_pending['write']) {
          _pending['write'].resolve();
          delete _pending['write'];
        }
        break;

      case 'onWriteError':
        if (_pending['write']) {
          _pending['write'].reject(new DOMException(data.error, 'NetworkError'));
          delete _pending['write'];
        }
        break;
    }
  };

  // Normalize UUID: handles numbers, short UUIDs, and full strings.
  // Returns an array of possible UUID forms to match against.
  function _normalizeUuid(uuid) {
    var candidates = [];

    if (typeof uuid === 'number') {
      // Could be hex like 0xFFE0 or decimal like 6172
      var hex = uuid.toString(16).padStart(4, '0');
      candidates.push('0000' + hex + '-0000-1000-8000-00805f9b34fb');
      candidates.push(hex);
      return candidates;
    }

    var str = String(uuid).toLowerCase().trim();
    candidates.push(str);

    // Full UUID — return as-is
    if (/^[0-9a-f]{8}-[0-9a-f]{4}-/.test(str)) {
      return candidates;
    }

    // Could be a decimal number string like "6172"
    if (/^\d+$/.test(str)) {
      var asHex = parseInt(str, 10).toString(16).padStart(4, '0');
      candidates.push('0000' + asHex + '-0000-1000-8000-00805f9b34fb');
      candidates.push(asHex);
      // Also treat as hex directly
      var padded = str.padStart(4, '0');
      candidates.push('0000' + padded + '-0000-1000-8000-00805f9b34fb');
      candidates.push(padded);
    }

    // Short hex UUID (4 chars)
    if (/^[0-9a-f]{4}$/.test(str)) {
      candidates.push('0000' + str + '-0000-1000-8000-00805f9b34fb');
    }

    // 8-char hex
    if (/^[0-9a-f]{8}$/.test(str)) {
      candidates.push(str + '-0000-1000-8000-00805f9b34fb');
    }

    return candidates;
  }

  // Check if a service/characteristic UUID matches any candidate
  function _uuidMatches(actualUuid, candidates) {
    var actual = actualUuid.toLowerCase();
    for (var i = 0; i < candidates.length; i++) {
      if (actual.includes(candidates[i]) || candidates[i].includes(actual)) {
        return true;
      }
    }
    return false;
  }

  function _createGattServer(connectionData) {
    const services = connectionData.services || [];

    return {
      connected: true,
      connect: function() {
        return Promise.resolve(this);
      },
      disconnect: function() {
        window.FlutterBluetooth.postMessage(JSON.stringify({
          action: 'disconnect'
        }));
        this.connected = false;
      },
      getPrimaryService: function(serviceUuid) {
        var candidates = _normalizeUuid(serviceUuid);
        const svc = services.find(s => _uuidMatches(s.uuid, candidates));
        if (!svc) {
          console.warn('[Biota1] Service not found:', serviceUuid, 'candidates:', candidates, 'available:', services.map(s => s.uuid));
          return Promise.reject(new DOMException(
            'Service not found: ' + serviceUuid, 'NotFoundError'
          ));
        }
        return Promise.resolve(_createService(svc));
      },
      getPrimaryServices: function() {
        return Promise.resolve(services.map(s => _createService(s)));
      }
    };
  }

  function _createService(svc) {
    return {
      uuid: svc.uuid,
      getCharacteristic: function(charUuid) {
        var candidates = _normalizeUuid(charUuid);
        const ch = svc.characteristics.find(c => _uuidMatches(c.uuid, candidates));
        if (!ch) {
          console.warn('[Biota1] Characteristic not found:', charUuid, 'candidates:', candidates, 'available:', svc.characteristics.map(c => c.uuid));
          return Promise.reject(new DOMException(
            'Characteristic not found: ' + charUuid, 'NotFoundError'
          ));
        }
        return Promise.resolve(_createCharacteristic(ch));
      },
      getCharacteristics: function() {
        return Promise.resolve(
          svc.characteristics.map(c => _createCharacteristic(c))
        );
      }
    };
  }

  function _createCharacteristic(ch) {
    const characteristic = {
      uuid: ch.uuid,
      properties: {
        read: ch.properties.includes('read'),
        write: ch.properties.includes('write'),
        writeWithoutResponse: ch.properties.includes('writeWithoutResponse'),
        notify: ch.properties.includes('notify'),
        indicate: ch.properties.includes('indicate'),
      },
      writeValue: function(value) {
        return new Promise(function(resolve, reject) {
          _pending['write'] = { resolve: resolve, reject: reject };
          const bytes = Array.from(new Uint8Array(value.buffer || value));
          const b64 = btoa(String.fromCharCode.apply(null, bytes));
          window.FlutterBluetooth.postMessage(JSON.stringify({
            action: 'write',
            data: b64,
            charUuid: ch.uuid
          }));
        });
      },
      startNotifications: function() {
        if (!_characteristicListeners[ch.uuid]) {
          _characteristicListeners[ch.uuid] = [];
        }
        return Promise.resolve(characteristic);
      },
      stopNotifications: function() {
        _characteristicListeners[ch.uuid] = [];
        return Promise.resolve(characteristic);
      },
      addEventListener: function(event, callback) {
        if (event === 'characteristicvaluechanged') {
          if (!_characteristicListeners[ch.uuid]) {
            _characteristicListeners[ch.uuid] = [];
          }
          _characteristicListeners[ch.uuid].push(callback);
        }
      },
      removeEventListener: function(event, callback) {
        if (_characteristicListeners[ch.uuid]) {
          _characteristicListeners[ch.uuid] =
            _characteristicListeners[ch.uuid].filter(cb => cb !== callback);
        }
      }
    };
    return characteristic;
  }

  // Polyfill navigator.bluetooth
  navigator.bluetooth = {
    requestDevice: function(options) {
      return new Promise(function(resolve, reject) {
        _pending['requestDevice'] = {
          resolve: function(device) {
            // When device is selected, we need to connect
            resolve(device);
          },
          reject: reject
        };
        _pending['connect'] = {
          resolve: function(device) {
            // Auto-resolve requestDevice when connection succeeds
            if (_pending['requestDevice']) {
              _pending['requestDevice'].resolve(device);
              delete _pending['requestDevice'];
            }
          },
          reject: function(err) {
            if (_pending['requestDevice']) {
              _pending['requestDevice'].reject(err);
              delete _pending['requestDevice'];
            }
          }
        };

        // Extract name filter from options
        var nameFilter = '';
        if (options && options.filters) {
          for (var f of options.filters) {
            if (f.namePrefix) { nameFilter = f.namePrefix; break; }
            if (f.name) { nameFilter = f.name; break; }
          }
        }

        // Tell Flutter to show the native device picker
        window.FlutterBluetooth.postMessage(JSON.stringify({
          action: 'requestDevice',
          nameFilter: nameFilter
        }));
      });
    },
    getAvailability: function() {
      return Promise.resolve(true);
    }
  };

  console.log('[Biota1] Bluetooth bridge polyfill installed');
})();
''';
