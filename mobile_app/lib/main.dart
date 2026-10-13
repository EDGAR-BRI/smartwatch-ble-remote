import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

// Anulación de validación SSL para permitir certificados autofirmados
class DevHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback = (X509Certificate cert, String host, int port) => true;
  }
}

const String defaultPcUrl = "10.0.0.3:8888";
const String targetMac = "41:42:2E:78:9B:68";
const String nusServiceUuid = "6e400001-b5a3-f393-e0a9-e50e24dcca9f";
const String nusWriteCharUuid = "6e400002-b5a3-f393-e0a9-e50e24dcca9f";
const String nusNotifyCharUuid = "6e400003-b5a3-f393-e0a9-e50e24dcca9f";
const String battCharUuid = "00002a19-0000-1000-8000-00805f9b34fb";

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = DevHttpOverrides();
  runApp(const SmartwatchPresenterApp());
}

class SmartwatchPresenterApp extends StatelessWidget {
  const SmartwatchPresenterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smartwatch Presenter',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0F172A),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF38BDF8),
          surface: Color(0xFF1E293B),
        ),
      ),
      home: const PresenterScreen(),
    );
  }
}

class PresenterScreen extends StatefulWidget {
  const PresenterScreen({super.key});

  @override
  State<PresenterScreen> createState() => _PresenterScreenState();
}

class _PresenterScreenState extends State<PresenterScreen> {
  final TextEditingController _pcController = TextEditingController(text: defaultPcUrl);

  BluetoothDevice? _device;
  BluetoothCharacteristic? _writeChar;
  StreamSubscription? _scanSub;
  StreamSubscription? _valueSub;
  StreamSubscription? _stateSub;
  StreamSubscription? _adapterSub;
  WebSocketChannel? _channel;
  Timer? _wsReconnectTimer;
  Timer? _heartbeatTimer;

  bool _isBleConnected = false;
  bool _isWsConnected = false;
  bool _isScanning = false;
  bool _bluetoothEnabled = true;
  bool _permissionsGranted = false;
  int? _lastSequence;
  String _watchBattery = "--%";
  String _lastActionText = "Esperando pulsación...";
  Color _flashColor = Colors.transparent;
  final List<String> _logs = [];
  final Map<String, ScanResult> _discoveredMap = {};

  @override
  void initState() {
    super.initState();
    _initApp();
  }

  Future<void> _initApp() async {
    try {
      await WakelockPlus.enable();
    } catch (_) {}

    await _requestPermissions();
    _listenAdapterState();
    _connectWebSocket();
    if (_permissionsGranted) {
      _startScan();
    }
  }

  void _log(String msg) {
    if (!mounted) return;
    setState(() {
      final now = DateTime.now().toIso8601String().substring(11, 19);
      _logs.insert(0, "[$now] $msg");
      if (_logs.length > 80) _logs.removeLast();
    });
  }

  // 1. Permisos Android (Bluetooth Scan, Connect, Location)
  Future<void> _requestPermissions() async {
    _log("[+] Comprobando permisos...");
    if (Platform.isAndroid) {
      final statuses = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
      ].request();

      final scanOk = statuses[Permission.bluetoothScan]?.isGranted ?? true;
      final connOk = statuses[Permission.bluetoothConnect]?.isGranted ?? true;
      final locOk = statuses[Permission.locationWhenInUse]?.isGranted ?? true;

      setState(() {
        _permissionsGranted = (scanOk && connOk) || locOk;
      });

      if (_permissionsGranted) {
        _log("✓ Permisos concedidos");
      } else {
        _log("[!] Faltan permisos de Dispositivos Cercanos o Ubicación");
      }
    } else {
      setState(() => _permissionsGranted = true);
    }
  }

  // Monitorear estado del Bluetooth del teléfono
  void _listenAdapterState() {
    _adapterSub = FlutterBluePlus.adapterState.listen((state) {
      final isEnabled = state == BluetoothAdapterState.on;
      setState(() => _bluetoothEnabled = isEnabled);
      if (!isEnabled) {
        _log("[!] Bluetooth apagado en el teléfono");
      } else {
        _log("✓ Bluetooth encendido");
      }
    });
  }

  // 2. Conexión WebSocket con la PC Linux (WSS en puerto 8888 o WS en 8080)
  void _connectWebSocket() {
    _wsReconnectTimer?.cancel();
    final target = _pcController.text.trim();
    if (target.isEmpty) return;

    try {
      final Uri uri;
      if (target.startsWith("ws://") || target.startsWith("wss://")) {
        uri = Uri.parse(target);
      } else {
        // Por defecto usar wss:// si puerto es 8888 (puerto abierto en UFW)
        final scheme = target.contains(":8080") ? "ws" : "wss";
        final path = target.endsWith("/ws") ? target : "$target/ws";
        uri = Uri.parse("$scheme://$path");
      }

      _log("Conectando WS a $uri...");
      
      // IOWebSocketChannel utiliza HttpClient global con DevHttpOverrides
      _channel = IOWebSocketChannel.connect(
        uri,
        pingInterval: const Duration(seconds: 5),
      );

      _channel!.stream.listen(
        (message) {
          if (!_isWsConnected) {
            setState(() => _isWsConnected = true);
            _log("✓ WebSocket con PC CONECTADO");
          }
          try {
            final data = jsonDecode(message.toString());
            if (data['action'] == 'forward') {
              _triggerFlash(Colors.green, "⏩ AVANZAR (Diapositiva)");
            } else if (data['action'] == 'back') {
              _triggerFlash(Colors.blue, "⏪ RETROCEDER (Diapositiva)");
            }
          } catch (_) {}
        },
        onDone: () {
          setState(() => _isWsConnected = false);
          _log("[!] WS cerrado por el servidor. Reintentando en 3s...");
          _wsReconnectTimer = Timer(const Duration(seconds: 3), _connectWebSocket);
        },
        onError: (err) {
          setState(() => _isWsConnected = false);
          _log("[!] Error WS: $err");
          _wsReconnectTimer = Timer(const Duration(seconds: 3), _connectWebSocket);
        },
      );

      // Enviar saludo inicial
      _sendWs("hello");
      setState(() => _isWsConnected = true);
    } catch (e) {
      setState(() => _isWsConnected = false);
      _log("[!] Excepción al conectar WS: $e");
      _wsReconnectTimer = Timer(const Duration(seconds: 3), _connectWebSocket);
    }
  }

  void _sendWs(String event, {int sequence = -1}) {
    if (_channel != null) {
      try {
        _channel!.sink.add(jsonEncode({
          "event": event,
          "sequence": sequence,
          "timestamp": DateTime.now().millisecondsSinceEpoch,
        }));
      } catch (e) {
        _log("[!] Error envío WS: $e");
      }
    }
  }

  // 3. Bluetooth Low Energy con Smartwatch
  Future<void> _startScan() async {
    if (_isBleConnected || _isScanning) return;

    if (!_permissionsGranted) {
      await _requestPermissions();
      if (!_permissionsGranted) {
        _log("[!] No se puede escanear sin permisos");
        return;
      }
    }

    setState(() {
      _isScanning = true;
      _discoveredMap.clear();
    });
    _log("[+] Buscando reloj...");

    // 1. Revisar si el reloj ya está emparejado o conectado al sistema Android
    try {
      final connected = FlutterBluePlus.connectedDevices;
      for (var d in connected) {
        if (_isTargetDevice(d.remoteId.str, d.platformName)) {
          _log("✓ Reloj ya conectado al sistema: ${d.platformName}");
          _connectToDevice(d);
          return;
        }
      }

      final sysDevices = await FlutterBluePlus.systemDevices([
        Guid("1800"),
        Guid(nusServiceUuid),
      ]);
      for (var d in sysDevices) {
        if (_isTargetDevice(d.remoteId.str, d.platformName)) {
          _log("✓ Reloj encontrado en sistema: ${d.platformName}");
          _connectToDevice(d);
          return;
        }
      }
    } catch (e) {
      _log("[i] Info dispositivos sistema: $e");
    }

    // 2. Escaneo activo BLE
    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 12));
      _scanSub?.cancel();
      _scanSub = FlutterBluePlus.scanResults.listen((results) {
        for (ScanResult r in results) {
          final id = r.device.remoteId.str;
          final name = r.device.platformName.isNotEmpty ? r.device.platformName : r.advertisementData.advName;
          
          if (!_discoveredMap.containsKey(id)) {
            setState(() {
              _discoveredMap[id] = r;
            });
          }

          if (_isTargetDevice(id, name)) {
            FlutterBluePlus.stopScan();
            setState(() => _isScanning = false);
            _connectToDevice(r.device);
            break;
          }
        }
      });
    } catch (e) {
      setState(() => _isScanning = false);
      _log("[!] Error al iniciar escaneo BLE: $e");
    }
  }

  bool _isTargetDevice(String id, String name) {
    final cleanId = id.toUpperCase();
    final cleanName = name.toUpperCase();
    if (cleanId == targetMac.toUpperCase()) return true;
    if (cleanName.contains("WATCH") || cleanName.contains("LAXAS") || cleanName.contains("HRY")) return true;
    return false;
  }

  bool _isConnecting = false;

  Future<void> _connectToDevice(BluetoothDevice device) async {
    if (_isConnecting || _isBleConnected) return;
    _isConnecting = true;

    _scanSub?.cancel();
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    setState(() => _isScanning = false);

    _device = device;
    final devName = device.platformName.isNotEmpty ? device.platformName : "Reloj";
    _log("[+] Enlazando con $devName (${device.remoteId.str})...");

    try {
      // Conexión activa directa (autoConnect: false)
      await device.connect(
        license: License.nonprofit,
        autoConnect: false,
        timeout: const Duration(seconds: 15),
      );

      setState(() => _isBleConnected = true);
      _log("✓ ¡Reloj Conectado exitosamente!");

      // Escuchar desconexión SÓLO después de haberse conectado exitosamente
      _stateSub?.cancel();
      _stateSub = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected && _isBleConnected) {
          setState(() {
            _isBleConnected = false;
            _watchBattery = "--%";
          });
          _log("[!] Reloj desconectado. Auto-reconectando en 3s...");
          _heartbeatTimer?.cancel();
          Future.delayed(const Duration(seconds: 3), () {
            if (!_isBleConnected && mounted) _startScan();
          });
        }
      });

      // Pausa para que la pila GATT se estabilice
      await Future.delayed(const Duration(milliseconds: 400));
      await _discoverAndSubscribe(device);

      // Prioridad BLE alta: reduce el intervalo de conexión a 11-15ms
      try {
        await device.requestConnectionPriority(connectionPriorityRequest: ConnectionPriority.high);
        _log("✓ Prioridad BLE Alta establecida");
      } catch (_) {}

    } catch (e) {
      _log("[!] Error enlazando reloj: $e");
      setState(() => _isBleConnected = false);
      Future.delayed(const Duration(seconds: 3), () {
        if (!_isBleConnected && mounted) _startScan();
      });
    } finally {
      _isConnecting = false;
    }
  }

  Future<void> _discoverAndSubscribe(BluetoothDevice device) async {
    _log("[+] Descubriendo características GATT...");
    try {
      List<BluetoothService> services = await device.discoverServices();
      BluetoothCharacteristic? notifyChar;
      BluetoothCharacteristic? writeChar;
      BluetoothCharacteristic? battChar;

      for (var s in services) {
        for (var c in s.characteristics) {
          final uuid = c.uuid.str128.toLowerCase();
          final shortUuid = c.uuid.str.toLowerCase();
          if (uuid == nusNotifyCharUuid.toLowerCase() || shortUuid == "6e400003") {
            notifyChar = c;
          } else if (uuid == nusWriteCharUuid.toLowerCase() || shortUuid == "6e400002") {
            writeChar = c;
          } else if (uuid == battCharUuid.toLowerCase() || shortUuid == "2a19") {
            battChar = c;
          }
        }
      }

      _writeChar = writeChar;

      // Si no encuentra el UUID exacto, buscar por prefijo 6e400003
      if (notifyChar == null) {
        for (var s in services) {
          for (var c in s.characteristics) {
            if (c.uuid.str.toLowerCase().contains("6e400003") ||
                (c.properties.notify && c.serviceUuid.str.toLowerCase().contains("6e400001"))) {
              notifyChar = c;
              break;
            }
          }
        }
      }

      if (notifyChar != null) {
        await notifyChar.setNotifyValue(true);
        _log("✓ Suscrito a eventos de obturador/cámara");

        _valueSub?.cancel();
        _valueSub = notifyChar.onValueReceived.listen((bytes) {
          _handleWatchPacket(bytes);
        });
      } else {
        _log("[!] No se halló característica de cámara NUS. Probando todas notify...");
        for (var s in services) {
          for (var c in s.characteristics) {
            if (c.properties.notify) {
              try {
                await c.setNotifyValue(true);
                c.onValueReceived.listen((bytes) => _handleWatchPacket(bytes));
                _log("✓ Escuchando notify en ${c.uuid.str}");
              } catch (_) {}
            }
          }
        }
      }

      // Canal de escritura y Keepalive Activo
      if (_writeChar != null) {
        _log("✓ Canal de control NUS listo");
        try {
          // Activar/mantener modo cámara en el reloj
          await _writeChar!.write([0xDF, 0x00, 0x04, 0x00, 0x0C, 0x01, 0x01], withoutResponse: true);
        } catch (_) {}

        // Ping periódico cada 4s (resetea el watchdog del reloj sin bloquear el hilo GATT)
        _heartbeatTimer?.cancel();
        _heartbeatTimer = Timer.periodic(const Duration(seconds: 4), (_) async {
          if (_isBleConnected && _writeChar != null) {
            try {
              await _writeChar!.write([0xDF, 0x00, 0x04, 0x00, 0x0C, 0x01, 0x01], withoutResponse: true);
            } catch (_) {}
          }
        });
      }

      // Batería (sólo lectura pasiva / notificación, sin bloqueo periódico)
      if (battChar != null) {
        try {
          if (battChar.properties.notify) {
            await battChar.setNotifyValue(true);
            battChar.onValueReceived.listen((bytes) {
              if (bytes.isNotEmpty && mounted) {
                setState(() => _watchBattery = "${bytes[0]}%");
              }
            });
          }
          final val = await battChar.read();
          if (val.isNotEmpty && mounted) {
            setState(() => _watchBattery = "${val[0]}%");
            _log("✓ Batería del reloj: ${val[0]}%");
          }
        } catch (_) {}
      }
    } catch (e) {
      _log("[!] Error en descubrimiento GATT: $e");
    }
  }

  void _handleWatchPacket(List<int> bytes) {
    if (bytes.isEmpty) return;

    final hexStr = bytes.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');
    _log("📦 RX: $hexStr");

    // Detección paquete disparador Laxasfit / HryFine: Header 0xDF ... Cmd 0x0C 0x01
    bool isShutter = false;
    int seq = -1;

    if (hexStr.contains("0C 01") || hexStr.startsWith("DF 00 06")) {
      isShutter = true;
      seq = bytes.length >= 7 ? bytes[6] : -1;
    } else if (bytes.length >= 2 && bytes[0] == 0x0C && bytes[1] == 0x01) {
      isShutter = true;
    }

    if (isShutter) {
      // Enviar ACK inmediato al reloj para que sepa que la foto fue tomada
      if (_writeChar != null) {
        try {
          final ack = List<int>.from(bytes);
          if (ack.isNotEmpty) {
            ack[ack.length - 1] = 0x00;
            _writeChar!.write(ack, withoutResponse: true);
            _log("✓ ACK enviado al reloj");
          }
        } catch (_) {}
      }

      // Desduplicar ráfagas con la misma secuencia
      if (seq != -1 && seq == _lastSequence) return;
      _lastSequence = seq;

      HapticFeedback.heavyImpact();
      _log("🎯 Disparo detectado (Seq: $seq) ➜ Enviando a PC");
      _sendWs("shutter", sequence: seq);
    }
  }

  void _triggerFlash(Color color, String text) {
    HapticFeedback.lightImpact();
    setState(() {
      _flashColor = color.withValues(alpha: 0.25);
      _lastActionText = text;
    });
    Future.delayed(const Duration(milliseconds: 600), () {
      if (mounted) setState(() => _flashColor = Colors.transparent);
    });
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _valueSub?.cancel();
    _stateSub?.cancel();
    _adapterSub?.cancel();
    _wsReconnectTimer?.cancel();
    _heartbeatTimer?.cancel();
    _channel?.sink.close();
    _device?.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Smartwatch Presenter', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        backgroundColor: const Color(0xFF1E293B),
        centerTitle: true,
        actions: [
          IconButton(
            icon: Icon(Icons.refresh, color: _isScanning ? Colors.amber : Colors.white),
            tooltip: 'Escanear Bluetooth',
            onPressed: _startScan,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
        child: Column(
          children: [
            // Banner de Bluetooth apagado o permisos
            if (!_bluetoothEnabled)
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.redAccent),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.bluetooth_disabled, color: Colors.redAccent),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text("El Bluetooth está apagado.", style: TextStyle(fontSize: 13)),
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                      onPressed: () => FlutterBluePlus.turnOn(),
                      child: const Text("Encender", style: TextStyle(color: Colors.white)),
                    ),
                  ],
                ),
              ),

            // Configuración IP PC
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(Icons.computer, color: Color(0xFF38BDF8)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _pcController,
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        hintText: "IP de la PC (ej: 10.0.0.3:8888)",
                        isDense: true,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.sync, color: Color(0xFF38BDF8)),
                    tooltip: 'Reconectar WebSocket',
                    onPressed: _connectWebSocket,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Estados de Conexión
            Row(
              children: [
                Expanded(
                  child: _StatusCard(
                    title: "Reloj (BLE)",
                    subtitle: _isBleConnected
                        ? "Conectado ($_watchBattery)"
                        : (_isScanning ? "Buscando..." : "Desconectado"),
                    icon: Icons.watch,
                    isConnected: _isBleConnected,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _StatusCard(
                    title: "PC (Wi-Fi)",
                    subtitle: _isWsConnected ? "Conectado" : "Desconectado",
                    icon: Icons.wifi,
                    isConnected: _isWsConnected,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),

            // Dispositivos encontrados (si no está conectado el reloj)
            if (!_isBleConnected && _discoveredMap.isNotEmpty) ...[
              Container(
                height: 100,
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white12),
                ),
                child: ListView(
                  children: _discoveredMap.values.map((r) {
                    final name = r.device.platformName.isNotEmpty
                        ? r.device.platformName
                        : (r.advertisementData.advName.isNotEmpty ? r.advertisementData.advName : "Dispositivo BLE");
                    return ListTile(
                      dense: true,
                      leading: const Icon(Icons.bluetooth, color: Color(0xFF38BDF8)),
                      title: Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                      subtitle: Text(r.device.remoteId.str, style: const TextStyle(fontSize: 11, color: Colors.white54)),
                      trailing: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF0284C7),
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        ),
                        onPressed: () => _connectToDevice(r.device),
                        child: const Text("Conectar", style: TextStyle(fontSize: 12)),
                      ),
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 10),
            ],

            // Indicador Visual de Diapositiva
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 20),
              decoration: BoxDecoration(
                color: _flashColor == Colors.transparent ? const Color(0xFF1E293B) : _flashColor,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: _flashColor == Colors.transparent ? Colors.white10 : const Color(0xFF38BDF8),
                  width: 2,
                ),
              ),
              child: Column(
                children: [
                  const Icon(Icons.touch_app, size: 40, color: Color(0xFF38BDF8)),
                  const SizedBox(height: 6),
                  Text(
                    _lastActionText,
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  const Text("1 toque = Siguiente | 2 toques = Anterior",
                      style: TextStyle(color: Colors.white54, fontSize: 11)),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Botones de Prueba Manual
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      backgroundColor: const Color(0xFF1E293B),
                    ),
                    icon: const Icon(Icons.arrow_back, size: 18),
                    label: const Text("Atrás"),
                    onPressed: () => _sendWs("back"),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      backgroundColor: const Color(0xFF0284C7),
                    ),
                    icon: const Icon(Icons.arrow_forward, size: 18),
                    label: const Text("Adelante"),
                    onPressed: () => _sendWs("forward"),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Registro de Consola / Logs
            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF090D16),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white10),
                ),
                child: ListView.builder(
                  itemCount: _logs.length,
                  itemBuilder: (context, i) => Text(
                    _logs[i],
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Colors.white70),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final bool isConnected;

  const _StatusCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.isConnected,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, color: isConnected ? Colors.greenAccent : Colors.redAccent, size: 26),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                Text(subtitle,
                    style: TextStyle(color: isConnected ? Colors.greenAccent : Colors.white54, fontSize: 11),
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
