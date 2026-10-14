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
const String appVersion = "1.0.7+8";
const String battCharUuid = "00002a19-0000-1000-8000-00805f9b34fb";
const MethodChannel _mediaChannel = MethodChannel('com.edgardev.mobile_app/media_session');

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
  bool _isMediaActive = false;
  bool _batteryOptIgnored = false;
  bool _bluetoothEnabled = true;
  bool _permissionsGranted = false;
  bool _isCheckingUpdate = false;
  bool _hapticEnabled = true;
  bool _isDiscovering = false;
  RawDatagramSocket? _discoverySocket;
  Timer? _discoveryTimeoutTimer;
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

    // Limpieza de APK previo si ya se completó una actualización
    try {
      final cacheDir = await _mediaChannel.invokeMethod<String>('getCacheDir');
      if (cacheDir != null) {
        final oldApk = File('$cacheDir/update.apk');
        if (await oldApk.exists()) {
          await oldApk.delete();
          _log("✓ Caché de actualización previa liberada");
        }
      }
    } catch (_) {}

    await _requestPermissions();
    _listenAdapterState();
    _startDiscovery(manual: false);
    _connectWebSocket();
    _setupMediaSession();
    if (_permissionsGranted) {
      _startScan();
    }
  }

  Future<void> _setupMediaSession() async {
    _mediaChannel.setMethodCallHandler((call) async {
      if (call.method == "onMediaAction") {
        final action = call.arguments?.toString() ?? "";
        if (action == "forward") {
          _log("🎵 Reloj (Botón/Rueda ➔) ➔ Avanzar");
          _triggerFlash(const Color(0xFF22C55E), "⏩ AVANZAR");
          _triggerHaptic("forward");
          _sendWs("forward");
        } else if (action == "back") {
          _log("🎵 Reloj (Botón/Rueda ⬅) ➔ Retroceder");
          _triggerFlash(const Color(0xFF38BDF8), "⏪ RETROCEDER");
          _triggerHaptic("back");
          _sendWs("back");
        } else if (action == "play_pause") {
          _log("🎵 Reloj ➔ Play/Pausa");
          _triggerFlash(Colors.purpleAccent, "⏯️ PLAY/PAUSA");
          _triggerHaptic("play_pause");
        }
      }
    });

    try {
      await _mediaChannel.invokeMethod('startMediaSession');
      if (mounted) setState(() => _isMediaActive = true);
      _log("✓ Simulador AVRCP activo (Controles Música)");
    } catch (e) {
      _log("[!] Error iniciando AVRCP: $e");
    }
  }

  Future<void> _toggleMediaSession(bool enable) async {
    try {
      if (enable) {
        await _mediaChannel.invokeMethod('startMediaSession');
        if (mounted) setState(() => _isMediaActive = true);
        _log("✓ Controles de música (AVRCP) activados");
      } else {
        await _mediaChannel.invokeMethod('stopMediaSession');
        if (mounted) setState(() => _isMediaActive = false);
        _log("[-] Controles de música desactivados");
      }
    } catch (e) {
      _log("[!] Error alternando AVRCP: $e");
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

  // 1. Permisos Android (Bluetooth, Notificaciones, Segundo Plano sin restricciones)
  Future<void> _requestPermissions() async {
    _log("[+] Comprobando permisos...");
    if (Platform.isAndroid) {
      final statuses = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
        Permission.notification,
      ].request();

      final scanOk = statuses[Permission.bluetoothScan]?.isGranted ?? true;
      final connOk = statuses[Permission.bluetoothConnect]?.isGranted ?? true;
      final locOk = statuses[Permission.locationWhenInUse]?.isGranted ?? true;

      // Solicitar permiso explícito de segundo plano (sin ahorro de batería)
      try {
        final isIgnored = await Permission.ignoreBatteryOptimizations.isGranted;
        if (!isIgnored) {
          _log("[+] Solicitando segundo plano sin cortes...");
          final reqResult = await Permission.ignoreBatteryOptimizations.request();
          _batteryOptIgnored = reqResult.isGranted;
        } else {
          _batteryOptIgnored = true;
        }
      } catch (_) {}

      setState(() {
        _permissionsGranted = (scanOk && connOk) || locOk;
      });

      if (_permissionsGranted) {
        _log("✓ Permisos Bluetooth concedidos");
      } else {
        _log("[!] Faltan permisos de Dispositivos Cercanos o Ubicación");
      }

      if (_batteryOptIgnored) {
        _log("✓ Segundo plano sin restricciones de batería");
      } else {
        _log("[!] Para evitar que se cierre con pantalla apagada, desactiva el ahorro de batería");
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
  Uri _getPcHttpUri(String path) {
    var raw = _pcController.text.trim();
    raw = raw.replaceFirst(RegExp(r'^(wss?|https?)://'), '');
    if (raw.endsWith('/')) raw = raw.substring(0, raw.length - 1);
    if (raw.endsWith('/ws')) raw = raw.substring(0, raw.length - 3);
    final isHttp = raw.contains(':8080');
    final scheme = isHttp ? 'http' : 'https';
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$scheme://$raw$normalizedPath');
  }

  Future<void> _checkForUpdates({bool manual = false}) async {
    if (_isCheckingUpdate) return;
    _isCheckingUpdate = true;

    try {
      if (manual) {
        _log("Buscando actualización en PC...");
      }

      final infoUri = _getPcHttpUri('/api/app-info');
      final client = HttpClient()..badCertificateCallback = ((c, h, p) => true);
      client.connectionTimeout = const Duration(seconds: 4);

      final request = await client.getUrl(infoUri);
      final response = await request.close().timeout(const Duration(seconds: 4));

      if (response.statusCode != 200) {
        if (manual) _log("[!] Error consultando versión: HTTP ${response.statusCode}");
        client.close();
        _isCheckingUpdate = false;
        return;
      }

      final responseBody = await response.transform(utf8.decoder).join();
      client.close();

      final data = jsonDecode(responseBody) as Map<String, dynamic>;
      final serverVersion = data['version']?.toString() ?? "";
      final sizeMb = data['size_mb']?.toString() ?? "";
      final apkExists = data['apk_exists'] == true;
      final buildTime = data['build_time']?.toString() ?? "";

      if (!apkExists) {
        if (manual && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("No se encontró ningún APK compilado en el servidor."),
              backgroundColor: Colors.orange,
            ),
          );
        }
        _isCheckingUpdate = false;
        return;
      }

      final hasUpdate = serverVersion.isNotEmpty && serverVersion != appVersion;

      if (!hasUpdate) {
        if (manual && mounted) {
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              backgroundColor: const Color(0xFF1E293B),
              title: const Row(
                children: [
                  Icon(Icons.check_circle, color: Color(0xFF22C55E)),
                  SizedBox(width: 8),
                  Text("App al día"),
                ],
              ),
              content: Text("Tienes la versión más reciente instalada:\nv$appVersion ($sizeMb)"),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text("Cerrar"),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF38BDF8)),
                  onPressed: () {
                    Navigator.pop(ctx);
                    _downloadAndInstallApk(serverVersion, sizeMb);
                  },
                  child: const Text("Reinstalar APK", style: TextStyle(color: Colors.black)),
                ),
              ],
            ),
          );
        }
        _isCheckingUpdate = false;
        return;
      }

      // Hay nueva versión disponible
      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1E293B),
            title: const Row(
              children: [
                Icon(Icons.system_update, color: Color(0xFF38BDF8)),
                SizedBox(width: 8),
                Text("Actualización Disponible"),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("Versión actual: v$appVersion", style: const TextStyle(color: Colors.white70)),
                const SizedBox(height: 4),
                Text("Nueva versión: v$serverVersion", style: const TextStyle(color: Color(0xFF38BDF8), fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(height: 4),
                Text("Tamaño: $sizeMb  •  Fecha: $buildTime", style: const TextStyle(color: Colors.white54, fontSize: 12)),
                const SizedBox(height: 12),
                const Text("¿Deseas descargar e instalar esta versión directamente?"),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text("Más tarde"),
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF22C55E),
                  foregroundColor: Colors.black,
                ),
                icon: const Icon(Icons.download, size: 18),
                label: const Text("Actualizar Ahora", style: TextStyle(fontWeight: FontWeight.bold)),
                onPressed: () {
                  Navigator.pop(ctx);
                  _downloadAndInstallApk(serverVersion, sizeMb);
                },
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (manual) {
        _log("[!] Error al verificar actualizaciones: $e");
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text("Error al buscar actualización: $e"),
              backgroundColor: Colors.redAccent,
            ),
          );
        }
      }
    } finally {
      _isCheckingUpdate = false;
    }
  }

  Future<void> _downloadAndInstallApk(String version, String sizeMb) async {
    try {
      // 1. Verificar permiso de instalación de fuentes desconocidas
      if (Platform.isAndroid) {
        final canInstall = await _mediaChannel.invokeMethod<bool>('canInstallApk') ?? true;
        if (!canInstall) {
          if (mounted) {
            final grant = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                backgroundColor: const Color(0xFF1E293B),
                title: const Text("Permiso de Instalación Requerido"),
                content: const Text(
                  "Android requiere autorización para instalar actualizaciones directamente desde esta aplicación.\n\n"
                  "Por favor presiona 'Autorizar' y activa 'Confiar en esta fuente'.",
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text("Cancelar"),
                  ),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF38BDF8)),
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text("Autorizar", style: TextStyle(color: Colors.black)),
                  ),
                ],
              ),
            );

            if (grant == true) {
              await _mediaChannel.invokeMethod('requestInstallPermission');
            }
            return;
          }
        }
      }

      // 2. Diálogo de progreso de descarga
      double progress = 0.0;
      String statusText = "Iniciando descarga...";
      StateSetter? dialogSetState;

      if (!mounted) return;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          return StatefulBuilder(
            builder: (context, setDState) {
              dialogSetState = setDState;
              return AlertDialog(
                backgroundColor: const Color(0xFF1E293B),
                title: Row(
                  children: [
                    const Icon(Icons.downloading, color: Color(0xFF38BDF8)),
                    const SizedBox(width: 8),
                    Text("Descargando v$version"),
                  ],
                ),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LinearProgressIndicator(
                      value: progress > 0 ? progress : null,
                      backgroundColor: Colors.white10,
                      valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF38BDF8)),
                    ),
                    const SizedBox(height: 14),
                    Text(statusText, style: const TextStyle(fontSize: 12, color: Colors.white70)),
                  ],
                ),
              );
            },
          );
        },
      );

      // 3. Descarga vía HttpClient al cache interno
      final cacheDir = await _mediaChannel.invokeMethod<String>('getCacheDir');
      final apkFile = File('$cacheDir/update.apk');
      if (await apkFile.exists()) {
        try {
          await apkFile.delete();
        } catch (_) {}
      }

      final client = HttpClient()..badCertificateCallback = ((c, h, p) => true);
      final request = await client.getUrl(_getPcHttpUri('/app.apk'));
      final response = await request.close();

      if (response.statusCode != 200) {
        throw Exception("Error del servidor: HTTP ${response.statusCode}");
      }

      final totalBytes = response.contentLength;
      int receivedBytes = 0;
      final sink = apkFile.openWrite();

      await response.forEach((chunk) {
        sink.add(chunk);
        receivedBytes += chunk.length;
        if (dialogSetState != null && totalBytes > 0) {
          dialogSetState!(() {
            progress = receivedBytes / totalBytes;
            final rec = (receivedBytes / (1024 * 1024)).toStringAsFixed(1);
            final tot = (totalBytes / (1024 * 1024)).toStringAsFixed(1);
            final pct = (progress * 100).toInt();
            statusText = "$pct% ($rec / $tot MB)";
          });
        }
      });

      await sink.close();
      client.close();

      if (mounted) {
        try {
          Navigator.of(context, rootNavigator: true).pop(); // Cierra el diálogo de progreso
        } catch (_) {}
      }

      _log("✓ Descarga finalizada: ${(receivedBytes / (1024 * 1024)).toStringAsFixed(1)} MB");
      _log("Abriendo instalador del sistema...");

      // 4. Lanzar instalación con FileProvider
      await _mediaChannel.invokeMethod('installApk', {'filePath': apkFile.path});

    } catch (e) {
      if (mounted) {
        try {
          Navigator.of(context, rootNavigator: true).pop();
        } catch (_) {}
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1E293B),
            title: const Text("Error de Descarga"),
            content: Text("Ocurrió un error al descargar la actualización:\n$e"),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text("Entendido"),
              ),
            ],
          ),
        );
      }
      _log("[!] Error actualizando app: $e");
    }
  }

  void _triggerHaptic(String action) {
    if (!_hapticEnabled) return;
    try {
      if (action == "forward") {
        HapticFeedback.mediumImpact();
      } else if (action == "back") {
        HapticFeedback.lightImpact();
        Future.delayed(const Duration(milliseconds: 110), () {
          HapticFeedback.lightImpact();
        });
      } else if (action == "play_pause") {
        HapticFeedback.heavyImpact();
      }
    } catch (_) {}
  }

  Future<void> _startDiscovery({bool manual = false}) async {
    if (_isDiscovering) return;
    if (_isWsConnected && !manual) return;

    setState(() => _isDiscovering = true);
    if (manual) _log("🔍 Buscando laptop en la red local...");

    try {
      _discoverySocket?.close();
      _discoverySocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _discoverySocket!.broadcastEnabled = true;

      _discoverySocket!.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          final datagram = _discoverySocket?.receive();
          if (datagram != null) {
            try {
              final text = utf8.decode(datagram.data);
              final data = jsonDecode(text) as Map<String, dynamic>;
              if (data['service'] == 'smartwatch-presenter') {
                final ip = data['ip']?.toString() ?? datagram.address.address;
                final port = data['port']?.toString() ?? "8888";
                final target = "$ip:$port";

                if (mounted) {
                  setState(() {
                    _pcController.text = target;
                    _isDiscovering = false;
                  });
                }
                _log("✓ ¡Laptop detectada!: $target");
                _discoveryTimeoutTimer?.cancel();
                _discoverySocket?.close();
                _discoverySocket = null;

                if (!_isWsConnected) {
                  _connectWebSocket();
                }
              }
            } catch (_) {}
          }
        }
      });

      // Enviar solicitud de broadcast a 255.255.255.255:8889
      final probe = utf8.encode("DISCOVER_SMARTWATCH_PRESENTER");
      _discoverySocket!.send(probe, InternetAddress("255.255.255.255"), 8889);

      // Reintento rápido a los 800ms
      Future.delayed(const Duration(milliseconds: 800), () {
        if (_isDiscovering && _discoverySocket != null) {
          try {
            _discoverySocket!.send(probe, InternetAddress("255.255.255.255"), 8889);
          } catch (_) {}
        }
      });

      _discoveryTimeoutTimer?.cancel();
      _discoveryTimeoutTimer = Timer(const Duration(seconds: 4), () {
        if (mounted && _isDiscovering) {
          setState(() => _isDiscovering = false);
          _discoverySocket?.close();
          _discoverySocket = null;
          if (manual) {
            _log("[!] No se detectó laptop en Wi-Fi. Puedes usar la IP manual.");
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text("No se encontró la laptop. Verifica que web_bridge esté corriendo en la misma red Wi-Fi."),
                backgroundColor: Colors.orange,
              ),
            );
          }
        }
      });
    } catch (e) {
      if (mounted) setState(() => _isDiscovering = false);
      if (manual) _log("[!] Error en auto-descubrimiento: $e");
    }
  }

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
            _checkForUpdates(manual: false);
          }
          try {
            final data = jsonDecode(message.toString());
            if (data['action'] == 'forward') {
              _triggerFlash(Colors.green, "⏩ AVANZAR (Diapositiva)");
              _triggerHaptic("forward");
            } else if (data['action'] == 'back') {
              _triggerFlash(Colors.blue, "⏪ RETROCEDER (Diapositiva)");
              _triggerHaptic("back");
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
      _checkForUpdates(manual: false);
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

      _triggerHaptic("forward");
      _log("🎯 Disparo detectado (Seq: $seq) ➜ Enviando a PC");
      _sendWs("shutter", sequence: seq);
    }
  }

  void _triggerFlash(Color color, String text) {
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
    _discoveryTimeoutTimer?.cancel();
    _discoverySocket?.close();
    _scanSub?.cancel();
    _valueSub?.cancel();
    _stateSub?.cancel();
    _adapterSub?.cancel();
    _wsReconnectTimer?.cancel();
    _heartbeatTimer?.cancel();
    _channel?.sink.close();
    _device?.disconnect();
    _mediaChannel.invokeMethod('stopMediaSession').catchError((_) {});
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Smartwatch Presenter', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
            Text('v$appVersion • Rueda + Música + BLE', style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 11, fontWeight: FontWeight.normal)),
          ],
        ),
        backgroundColor: const Color(0xFF1E293B),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.system_update_alt, color: Color(0xFF38BDF8)),
            tooltip: 'Buscar Actualización (OTA)',
            onPressed: () => _checkForUpdates(manual: true),
          ),
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

            // Banner de optimización de batería (Segundo Plano)
            if (!_batteryOptIgnored && Platform.isAndroid)
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.amber.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.amber.withValues(alpha: 0.5)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.battery_alert, color: Colors.amber, size: 20),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text("Habilitar segundo plano sin cortes", style: TextStyle(fontSize: 12)),
                    ),
                    TextButton(
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.amber,
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      ),
                      onPressed: () async {
                        await Permission.ignoreBatteryOptimizations.request();
                        final ok = await Permission.ignoreBatteryOptimizations.isGranted;
                        if (mounted) setState(() => _batteryOptIgnored = ok);
                      },
                      child: const Text("Activar", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
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
                    icon: Icon(
                      Icons.radar,
                      color: _isDiscovering ? Colors.amber : const Color(0xFF38BDF8),
                    ),
                    tooltip: 'Auto-detectar Laptop en Wi-Fi',
                    onPressed: () => _startDiscovery(manual: true),
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
            const SizedBox(height: 12),

            // Tarjeta de Controles Multimedia AVRCP
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _isMediaActive ? const Color(0xFF22C55E).withValues(alpha: 0.4) : Colors.white10,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _isMediaActive ? Icons.music_note : Icons.music_off,
                    color: _isMediaActive ? const Color(0xFF22C55E) : Colors.white38,
                    size: 24,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text("Música y Rueda del Reloj", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                        Text(
                          _isMediaActive ? "Activo: ⏭️ Siguiente, ⏮️ Atrás y 🎛️ Rueda" : "Simulador desactivado",
                          style: TextStyle(color: _isMediaActive ? const Color(0xFF22C55E) : Colors.white38, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: _isMediaActive,
                    activeTrackColor: const Color(0xFF22C55E),
                    onChanged: _toggleMediaSession,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),

            // Tarjeta de Feedback Háptico (Vibración en Bolsillo)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _hapticEnabled ? const Color(0xFF38BDF8).withValues(alpha: 0.3) : Colors.white10,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _hapticEnabled ? Icons.vibration : Icons.mobile_off,
                    color: _hapticEnabled ? const Color(0xFF38BDF8) : Colors.white38,
                    size: 22,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text("Vibración Háptica (Bolsillo)", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                        Text(
                          _hapticEnabled ? "1 vib = ⏩ Avanzar | 2 vibs = ⏪ Retroceder" : "Vibración táctil desactivada",
                          style: TextStyle(color: _hapticEnabled ? const Color(0xFF38BDF8) : Colors.white38, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: _hapticEnabled,
                    activeTrackColor: const Color(0xFF38BDF8),
                    onChanged: (val) {
                      setState(() => _hapticEnabled = val);
                      if (val) HapticFeedback.mediumImpact();
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

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
