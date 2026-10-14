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
const String appVersion = "1.0.12+13";
const String githubLatestApkUrl = "https://github.com/EDGAR-BRI/smartwatch-ble-remote/releases/latest/download/BTClicker.apk";
const String githubLatestReleaseUrl = "https://github.com/EDGAR-BRI/smartwatch-ble-remote/releases/latest";
const String battCharUuid = "00002a19-0000-1000-8000-00805f9b34fb";
const MethodChannel _mediaChannel = MethodChannel('com.edgardev.mobile_app/media_session');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = DevHttpOverrides();
  runApp(const BTClickerApp());
}

class BTClickerApp extends StatelessWidget {
  const BTClickerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BT Clicker',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF070A11),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00F0FF),
          surface: Color(0xFF0E1526),
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
  bool _showSplash = true;
  int _bootStep = 0;
  int _actionCount = 0;
  Timer? _bootTimer;
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
    _bootTimer = Timer.periodic(const Duration(milliseconds: 400), (t) {
      if (!mounted) return;
      if (_bootStep < 4) {
        setState(() => _bootStep++);
      } else {
        t.cancel();
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted) setState(() => _showSplash = false);
        });
      }
    });

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
          _log("🎵 Reloj ➔ Pausa (Tecla U)");
          _triggerFlash(Colors.purpleAccent, "⏯️ PAUSA (U)");
          _triggerHaptic("play_pause");
          _sendWs("play_pause");
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

      try {
        final hasVibe = await _mediaChannel.invokeMethod<bool>('hasVibrator') ?? false;
        if (hasVibe) {
          _log("✓ Permiso y motor de vibración táctil: Activo");
        }
      } catch (_) {}

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
      final source = apkExists ? "PC Local (Wi-Fi)" : "GitHub Releases";
      final buildTime = data['build_time']?.toString() ?? "";

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
                Text("Tamaño: $sizeMb  •  $source ($buildTime)", style: const TextStyle(color: Colors.white54, fontSize: 12)),
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
      HttpClientResponse response;
      try {
        final request = await client.getUrl(_getPcHttpUri('/app.apk'));
        response = await request.close();
        if (response.statusCode != 200) {
          throw Exception("HTTP ${response.statusCode}");
        }
      } catch (pcErr) {
        _log("[!] Descargando APK desde GitHub Releases...");
        final request = await client.getUrl(Uri.parse(githubLatestApkUrl));
        response = await request.close();
        if (response.statusCode != 200) {
          throw Exception("Error descargando desde GitHub: HTTP ${response.statusCode}");
        }
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
      // 1. Motor de vibración de hardware nativo Android (funciona con pantalla apagada en el bolsillo)
      _mediaChannel.invokeMethod('vibrate', {'pattern': action});

      // 2. Feedback táctil de la interfaz Flutter
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
            } else if (data['action'] == 'play_pause') {
              _triggerFlash(Colors.purpleAccent, "⏯️ PAUSA (Tecla U)");
              _triggerHaptic("play_pause");
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
      _actionCount++;
      _flashColor = color.withValues(alpha: 0.25);
      _lastActionText = text;
    });
    Future.delayed(const Duration(milliseconds: 600), () {
      if (mounted) setState(() => _flashColor = Colors.transparent);
    });
  }

  @override
  void dispose() {
    _bootTimer?.cancel();
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

  Widget _buildMascotCard() {
    String mascotMessage;
    Color accentColor;
    String statusText;

    if (_isBleConnected && _isWsConnected) {
      mascotMessage = "Todo sincronizado. Inyectando KEY_RIGHT y KEY_LEFT en /dev/uinput.";
      accentColor = const Color(0xFF10B981);
      statusText = "ONLINE";
    } else if (_isBleConnected && !_isWsConnected) {
      mascotMessage = "Dispositivo BLE enlazado. Pulsa [RADAR] para enlazar laptop Wi-Fi.";
      accentColor = const Color(0xFF00F0FF);
      statusText = "BLE_ACTIVE";
    } else if (!_isBleConnected && _isWsConnected) {
      mascotMessage = "Laptop conectada. Escuchando Smartwatch, Auriculares BT y mandos BLE.";
      accentColor = const Color(0xFFF59E0B);
      statusText = "WS_ACTIVE";
    } else {
      mascotMessage = "Listo: Usa Smartwatch, Auriculares Bluetooth (toque de pista) o BLE.";
      accentColor = const Color(0xFF00F0FF);
      statusText = "STANDBY";
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF0B1120),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: accentColor.withValues(alpha: 0.35), width: 1),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () {
            HapticFeedback.lightImpact();
            ScaffoldMessenger.of(context).removeCurrentSnackBar();
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  "⚡ Sparky: 'BT Clicker: 1 toque = KEY_RIGHT | 2 toques = KEY_LEFT | Pausa = KEY_U'",
                  style: TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
                duration: Duration(seconds: 2),
                backgroundColor: Color(0xFF0E1526),
              ),
            );
          },
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Container(width: 6, height: 6, decoration: BoxDecoration(color: accentColor, shape: BoxShape.circle)),
                        const SizedBox(width: 6),
                        const Text(
                          "sh -- sparky@copilot:status",
                          style: TextStyle(fontFamily: 'monospace', fontSize: 10, color: Color(0xFF64748B)),
                        ),
                      ],
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: accentColor.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: Text(
                        statusText,
                        style: TextStyle(fontFamily: 'monospace', fontSize: 9, fontWeight: FontWeight.bold, color: accentColor),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: const Color(0xFF0E1526),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: accentColor.withValues(alpha: 0.5), width: 1),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(5),
                        child: Image.asset('assets/images/mascot.png', fit: BoxFit.cover),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "> $mascotMessage",
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                              color: Color(0xFFCBD5E1),
                              height: 1.3,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            "EVENTS: $_actionCount  •  BUS: /dev/uinput  •  LATENCY: <3ms",
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 9,
                              color: Color(0xFF64748B),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDeveloperSplashScreen() {
    final bootLogs = [
      "00.12s [SYS] Mounting Linux uinput driver...",
      "00.45s [BLE] Bluetooth Low Energy GATT NUS armed",
      "00.90s [NET] UDP Discovery beacon on :8889",
      "01.40s [AVRCP] MediaSession event listener ready",
      "01.90s [OK] Sparky BT Clicker engine online",
    ];

    final progress = (_bootStep + 1) / 5.0;

    return Scaffold(
      backgroundColor: const Color(0xFF070A11),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 20.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: Color(0xFF10B981),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        "SYS_BOOT // KERNEL v1.0.12",
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          color: Color(0xFF64748B),
                          letterSpacing: 1.0,
                        ),
                      ),
                    ],
                  ),
                  TextButton(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: () {
                      _bootTimer?.cancel();
                      if (mounted) setState(() => _showSplash = false);
                    },
                    child: const Text(
                      "[ SALTAR ]",
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: Color(0xFF00F0FF),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Stack(
                    alignment: Alignment.center,
                    children: [
                      Container(
                        width: 140,
                        height: 140,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF00F0FF).withValues(alpha: 0.22),
                              blurRadius: 40,
                              spreadRadius: 8,
                            ),
                          ],
                        ),
                      ),
                      Container(
                        width: 116,
                        height: 116,
                        decoration: BoxDecoration(
                          color: const Color(0xFF0E1526),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: const Color(0xFF00F0FF).withValues(alpha: 0.6),
                            width: 1.5,
                          ),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(15),
                          child: Image.asset(
                            'assets/images/mascot.png',
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text(
                        "BT",
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                          color: Colors.white,
                          letterSpacing: 1.5,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        "//",
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                          color: const Color(0xFF00F0FF).withValues(alpha: 0.8),
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        "CLICKER",
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                          color: Color(0xFF00F0FF),
                          letterSpacing: 1.5,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    "UNIVERSAL SLIDE REMOTE • RELOJ • AURICULARES • BLE",
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10,
                      color: Color(0xFF94A3B8),
                      letterSpacing: 0.8,
                    ),
                  ),
                ],
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF050811),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: const Color(0xFF1E293B),
                        width: 1,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              "BOOT SEQUENCE (STDERR/STDOUT):",
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 10,
                                color: Color(0xFF64748B),
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              "${(progress * 100).toInt()}%",
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 10,
                                color: Color(0xFF00F0FF),
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        for (int i = 0; i <= _bootStep && i < bootLogs.length; i++)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2.0),
                            child: Text(
                              "> ${bootLogs[i]}",
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11,
                                color: i == _bootStep ? const Color(0xFF00F0FF) : const Color(0xFF10B981),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 3,
                      backgroundColor: const Color(0xFF1E293B),
                      valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF00F0FF)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_showSplash) {
      return _buildDeveloperSplashScreen();
    }

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF090D14),
        elevation: 0,
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(color: Color(0xFF1E293B), height: 1, thickness: 1),
        ),
        leading: Padding(
          padding: const EdgeInsets.only(left: 14.0, top: 12.0, bottom: 12.0),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF0E1526),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: const Color(0xFF00F0FF).withValues(alpha: 0.4), width: 1),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(5),
              child: Image.asset(
                'assets/images/app_logo.png',
                fit: BoxFit.cover,
              ),
            ),
          ),
        ),
        title: Row(
          children: [
            const Text(
              'BT CLICKER',
              style: TextStyle(
                fontFamily: 'monospace',
                fontWeight: FontWeight.w900,
                fontSize: 14,
                letterSpacing: 1.0,
                color: Colors.white,
              ),
            ),
            const Text(
              '::DEV',
              style: TextStyle(
                fontFamily: 'monospace',
                fontWeight: FontWeight.bold,
                fontSize: 14,
                color: Color(0xFF00F0FF),
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF10B981).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: const Color(0xFF10B981).withValues(alpha: 0.4)),
              ),
              child: Text(
                'v$appVersion',
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 10,
                  color: Color(0xFF10B981),
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        centerTitle: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.system_update_alt, size: 20, color: Color(0xFF00F0FF)),
            tooltip: 'Buscar Actualización (OTA)',
            onPressed: () => _checkForUpdates(manual: true),
          ),
          IconButton(
            icon: Icon(Icons.refresh, size: 20, color: _isScanning ? Colors.amber : Colors.white),
            tooltip: 'Escanear Bluetooth',
            onPressed: _startScan,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 10.0),
        child: Column(
          children: [
            // Banner de Bluetooth apagado o permisos (Developer alert style)
            if (!_bluetoothEnabled)
              Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF450A0A).withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFFEF4444), width: 1),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.bluetooth_disabled, color: Color(0xFFEF4444), size: 18),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        "ERR: Bluetooth desactivado en el sistema",
                        style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: Color(0xFFFCA5A5)),
                      ),
                    ),
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Color(0xFFEF4444)),
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        visualDensity: VisualDensity.compact,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                      ),
                      onPressed: () => FlutterBluePlus.turnOn(),
                      child: const Text("ENCENDER", style: TextStyle(fontFamily: 'monospace', color: Colors.white, fontSize: 10)),
                    ),
                  ],
                ),
              ),

            // Banner de optimización de batería (Segundo Plano)
            if (!_batteryOptIgnored && Platform.isAndroid)
              Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF451A03).withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFFF59E0B), width: 1),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.battery_alert, color: Color(0xFFF59E0B), size: 18),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        "SYS: Habilitar segundo plano sin cortes",
                        style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: Color(0xFFFDE68A)),
                      ),
                    ),
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Color(0xFFF59E0B)),
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        visualDensity: VisualDensity.compact,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                      ),
                      onPressed: () async {
                        await Permission.ignoreBatteryOptimizations.request();
                        final ok = await Permission.ignoreBatteryOptimizations.isGranted;
                        if (mounted) setState(() => _batteryOptIgnored = ok);
                      },
                      child: const Text("ACTIVAR", style: TextStyle(fontFamily: 'monospace', color: Colors.white, fontSize: 10)),
                    ),
                  ],
                ),
              ),

            // Tarjeta Asistente Sparky (Mascota Copilot)
            _buildMascotCard(),

            // Configuración IP PC (Developer Prompt Bar)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF0B1120),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFF1E293B), width: 1),
              ),
              child: Row(
                children: [
                  const Text(
                    "HOST >",
                    style: TextStyle(
                      fontFamily: 'monospace',
                      color: Color(0xFF00F0FF),
                      fontWeight: FontWeight.bold,
                      fontSize: 11,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _pcController,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        color: Colors.white,
                      ),
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        hintText: "10.0.0.3:8888",
                        hintStyle: TextStyle(fontFamily: 'monospace', color: Colors.white24, fontSize: 12),
                        isDense: true,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      Icons.radar,
                      size: 18,
                      color: _isDiscovering ? Colors.amber : const Color(0xFF00F0FF),
                    ),
                    tooltip: 'Auto-detectar Laptop (UDP Beacon)',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _startDiscovery(manual: true),
                  ),
                  IconButton(
                    icon: const Icon(Icons.sync, size: 18, color: Color(0xFF00F0FF)),
                    tooltip: 'Reconectar WebSocket',
                    visualDensity: VisualDensity.compact,
                    onPressed: _connectWebSocket,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),

            // Telemetría de Nodos (Dual Node HUD)
            Row(
              children: [
                Expanded(
                  child: _StatusCard(
                    title: "NODE: SMARTWATCH_BLE",
                    subtitle: _isBleConnected
                        ? "CONN: ACTIVE [$_watchBattery]"
                        : (_isScanning ? "SCAN: BUSCANDO..." : "STATUS: OFFLINE"),
                    icon: Icons.watch,
                    isConnected: _isBleConnected,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _StatusCard(
                    title: "NODE: LINUX_HOST_WS",
                    subtitle: _isWsConnected ? "CONN: SYNCED (uinput)" : "STATUS: OFFLINE",
                    icon: Icons.terminal,
                    isConnected: _isWsConnected,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Tarjeta de Controles Multimedia AVRCP
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF0B1120),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: _isMediaActive ? const Color(0xFF10B981).withValues(alpha: 0.4) : const Color(0xFF1E293B),
                  width: 1,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _isMediaActive ? Icons.music_note : Icons.music_off,
                    color: _isMediaActive ? const Color(0xFF10B981) : Colors.white24,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          "AVRCP DAEMON (Música y Rueda Corona)",
                          style: TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold, fontSize: 11),
                        ),
                        Text(
                          _isMediaActive
                              ? "MAP: KEY_NEXTSONG / PREVSONG ➔ /dev/uinput"
                              : "STATUS: Inactivo (Pulsa para activar simulación)",
                          style: TextStyle(
                            fontFamily: 'monospace',
                            color: _isMediaActive ? const Color(0xFF10B981) : Colors.white38,
                            fontSize: 9,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Transform.scale(
                    scale: 0.8,
                    child: Switch(
                      value: _isMediaActive,
                      activeTrackColor: const Color(0xFF10B981),
                      onChanged: _toggleMediaSession,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),

            // Tarjeta de Feedback Háptico (Vibración en Bolsillo)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF0B1120),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: _hapticEnabled ? const Color(0xFF00F0FF).withValues(alpha: 0.35) : const Color(0xFF1E293B),
                  width: 1,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _hapticEnabled ? Icons.vibration : Icons.mobile_off,
                    color: _hapticEnabled ? const Color(0xFF00F0FF) : Colors.white24,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          "HAPTIC ENGINE (Vibración de Bolsillo)",
                          style: TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold, fontSize: 11),
                        ),
                        Text(
                          _hapticEnabled
                              ? "FEEDBACK: 1x VIB (AVANCE) • 2x VIB (RETROCESO)"
                              : "FEEDBACK: Desactivado",
                          style: TextStyle(
                            fontFamily: 'monospace',
                            color: _hapticEnabled ? const Color(0xFF00F0FF) : Colors.white38,
                            fontSize: 9,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Transform.scale(
                    scale: 0.8,
                    child: Switch(
                      value: _hapticEnabled,
                      activeTrackColor: const Color(0xFF00F0FF),
                      onChanged: (val) {
                        setState(() => _hapticEnabled = val);
                        if (val) _triggerHaptic("forward");
                      },
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),

            // Dispositivos encontrados (si no está conectado el reloj)
            if (!_isBleConnected && _discoveredMap.isNotEmpty) ...[
              Container(
                height: 90,
                decoration: BoxDecoration(
                  color: const Color(0xFF050811),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFF1E293B), width: 1),
                ),
                child: ListView(
                  children: _discoveredMap.values.map((r) {
                    final name = r.device.platformName.isNotEmpty
                        ? r.device.platformName
                        : (r.advertisementData.advName.isNotEmpty ? r.advertisementData.advName : "BLE_DEVICE");
                    return ListTile(
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      leading: const Icon(Icons.bluetooth_searching, size: 18, color: Color(0xFF00F0FF)),
                      title: Text(name, style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold, fontSize: 11)),
                      subtitle: Text(r.device.remoteId.str, style: const TextStyle(fontFamily: 'monospace', fontSize: 9, color: Colors.white54)),
                      trailing: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Color(0xFF00F0FF)),
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          visualDensity: VisualDensity.compact,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                        ),
                        onPressed: () => _connectToDevice(r.device),
                        child: const Text("LINK", style: TextStyle(fontFamily: 'monospace', fontSize: 10, color: Color(0xFF00F0FF))),
                      ),
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 8),
            ],

            // Indicador Visual de Diapositiva (HUD de Inyección)
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
              decoration: BoxDecoration(
                color: _flashColor == Colors.transparent ? const Color(0xFF090D16) : _flashColor,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: _flashColor == Colors.transparent ? const Color(0xFF1E293B) : const Color(0xFF00F0FF),
                  width: 1.5,
                ),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        "INJECTOR: /dev/uinput",
                        style: TextStyle(fontFamily: 'monospace', fontSize: 9, color: Color(0xFF64748B)),
                      ),
                      Text(
                        "SEQ: ${_lastSequence ?? 'IDLE'}",
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 9, color: Color(0xFF00F0FF)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _lastActionText,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.0,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    "1 toque = KEY_RIGHT  |  2 toques = KEY_LEFT  |  Pausa = KEY_U",
                    style: TextStyle(fontFamily: 'monospace', color: Colors.white38, fontSize: 10),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),

            // Botones de Prueba Manual (Mechanical Keycaps Style)
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      backgroundColor: const Color(0xFF090D16),
                      side: const BorderSide(color: Color(0xFF1E293B), width: 1),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                    ),
                    onPressed: () {
                      _triggerHaptic("back");
                      _triggerFlash(const Color(0xFF00F0FF), "⏪ KEY_LEFT (ATRÁS)");
                      _sendWs("back");
                    },
                    child: const Text(
                      "[ ◀ KEY_LEFT ]",
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.bold,
                        fontSize: 11,
                        color: Color(0xFFCBD5E1),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                    backgroundColor: const Color(0xFF3B0764).withValues(alpha: 0.35),
                    side: const BorderSide(color: Color(0xFFA855F7), width: 1),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                  ),
                  onPressed: () {
                    _triggerHaptic("play_pause");
                    _triggerFlash(Colors.purpleAccent, "⏯️ KEY_U (TELÓN)");
                    _sendWs("play_pause");
                  },
                  child: const Text(
                    "[ ⏸ KEY_U ]",
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.bold,
                      fontSize: 11,
                      color: Color(0xFFD8B4FE),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      backgroundColor: const Color(0xFF0284C7),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                    ),
                    onPressed: () {
                      _triggerHaptic("forward");
                      _triggerFlash(const Color(0xFF10B981), "⏩ KEY_RIGHT (ADELANTE)");
                      _sendWs("forward");
                    },
                    child: const Text(
                      "[ KEY_RIGHT ▶ ]",
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.bold,
                        fontSize: 11,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Registro de Consola / Terminal (stdout /dev/pts/1)
            Expanded(
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: const Color(0xFF050811),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFF1E293B), width: 1),
                ),
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: const BoxDecoration(
                        color: Color(0xFF090D16),
                        borderRadius: BorderRadius.vertical(top: Radius.circular(5)),
                        border: Border(bottom: BorderSide(color: Color(0xFF1E293B), width: 1)),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Container(width: 6, height: 6, decoration: const BoxDecoration(color: Color(0xFFEF4444), shape: BoxShape.circle)),
                              const SizedBox(width: 4),
                              Container(width: 6, height: 6, decoration: const BoxDecoration(color: Color(0xFFF59E0B), shape: BoxShape.circle)),
                              const SizedBox(width: 4),
                              Container(width: 6, height: 6, decoration: const BoxDecoration(color: Color(0xFF10B981), shape: BoxShape.circle)),
                              const SizedBox(width: 8),
                              const Text(
                                "stdout :: /dev/pts/1",
                                style: TextStyle(fontFamily: 'monospace', fontSize: 10, color: Color(0xFF64748B)),
                              ),
                            ],
                          ),
                          InkWell(
                            onTap: () => setState(() => _logs.clear()),
                            child: const Text(
                              "[ LIMPIAR ]",
                              style: TextStyle(fontFamily: 'monospace', fontSize: 9, color: Color(0xFF64748B)),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        padding: const EdgeInsets.all(8),
                        itemCount: _logs.length,
                        itemBuilder: (context, i) {
                          final line = _logs[i];
                          Color textColor = const Color(0xFF94A3B8);
                          if (line.contains("[!]")) {
                            textColor = const Color(0xFFF87171);
                          } else if (line.contains("✓") || line.contains("[OK]")) {
                            textColor = const Color(0xFF34D399);
                          } else if (line.contains("🎯") || line.contains("RX")) {
                            textColor = const Color(0xFF38BDF8);
                          } else if (line.contains("🎵")) {
                            textColor = const Color(0xFFC084FC);
                          }
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 1.0),
                            child: Text(
                              line,
                              style: TextStyle(fontFamily: 'monospace', fontSize: 10, color: textColor),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
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
    final color = isConnected ? const Color(0xFF10B981) : const Color(0xFFEF4444);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF090D16),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: isConnected ? color.withValues(alpha: 0.35) : const Color(0xFF1E293B),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.bold,
                          fontSize: 10,
                          color: Colors.white,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    color: color,
                    fontSize: 10,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
