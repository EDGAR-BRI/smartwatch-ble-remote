import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

// Validación SSL permisiva para servidores locales autofirmados
class DevHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback = (X509Certificate cert, String host, int port) => true;
  }
}

const String defaultPcUrl = "10.0.0.3:8888";
const String appVersion = "1.1.0+14";
const String githubLatestApkUrl =
    "https://github.com/EDGAR-BRI/smartwatch-ble-remote/releases/latest/download/BTPresenter.apk";
const String githubLatestReleaseUrl =
    "https://github.com/EDGAR-BRI/smartwatch-ble-remote/releases/latest";
const MethodChannel _mediaChannel =
    MethodChannel('com.edgardev.mobile_app/media_session');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = DevHttpOverrides();
  runApp(const BTPresenterApp());
}

class BTPresenterApp extends StatelessWidget {
  const BTPresenterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BT Presenter',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0F172A), // Slate 900
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF38BDF8), // Sky 400
          surface: Color(0xFF1E293B), // Slate 800
          secondary: Color(0xFF818CF8), // Indigo 400
        ),
        cardColor: const Color(0xFF1E293B),
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
  final TextEditingController _pcController =
      TextEditingController(text: defaultPcUrl);

  WebSocketChannel? _channel;
  Timer? _wsReconnectTimer;

  bool _isBtConnected = false;
  String _btDeviceName = "Desconectado";
  bool _isWsConnected = false;
  bool _isMediaActive = false;
  bool _batteryOptIgnored = false;
  bool _permissionsGranted = false;
  bool _isCheckingUpdate = false;
  bool _hapticEnabled = true;
  bool _isDiscovering = false;
  bool _showSplash = true;
  bool _showManualIp = false;
  bool _showActivityLog = false;
  int _actionCount = 0;
  RawDatagramSocket? _discoverySocket;
  Timer? _discoveryTimeoutTimer;

  String _lastActionText = "¡Listo para presentar!";
  String _lastActionSub = "Toca tus auriculares, reloj o los botones abajo";
  Color _flashColor = Colors.transparent;
  final List<String> _logs = [];

  @override
  void initState() {
    super.initState();
    _initApp();
  }

  Future<void> _initApp() async {
    // Splash screen limpio y rápido de 1.1 segundos
    Future.delayed(const Duration(milliseconds: 1100), () {
      if (mounted) setState(() => _showSplash = false);
    });

    try {
      await WakelockPlus.enable();
    } catch (_) {}

    // Limpieza de caché de APKs previos
    try {
      final cacheDir = await _mediaChannel.invokeMethod<String>('getCacheDir');
      if (cacheDir != null) {
        final oldApk = File('$cacheDir/update.apk');
        if (await oldApk.exists()) {
          await oldApk.delete();
        }
      }
    } catch (_) {}

    await _requestPermissions();
    _setupMediaSession();
    _startDiscovery(manual: false);
    _connectWebSocket();
  }

  Future<void> _setupMediaSession() async {
    _mediaChannel.setMethodCallHandler((call) async {
      if (call.method == "onMediaAction") {
        final action = call.arguments?.toString() ?? "";
        if (!_isBtConnected) {
          setState(() {
            _isBtConnected = true;
            if (_btDeviceName == "Desconectado") {
              _btDeviceName = "Dispositivo Bluetooth";
            }
          });
        }
        if (action == "forward") {
          _triggerAction(
            "forward",
            "⏩ Diapositiva Siguiente",
            "Disparo desde tus auriculares / reloj",
            const Color(0xFF38BDF8),
          );
        } else if (action == "back") {
          _triggerAction(
            "back",
            "⏪ Diapositiva Anterior",
            "Disparo desde tus auriculares / reloj",
            const Color(0xFFF43F5E),
          );
        } else if (action == "play_pause") {
          _triggerAction(
            "play_pause",
            "⏸️ Telón Negro (Pausa)",
            "Ocultar o pausar pantalla de diapositivas",
            const Color(0xFFA855F7),
          );
        }
      } else if (call.method == "onBluetoothDeviceState") {
        final args = call.arguments as Map<dynamic, dynamic>?;
        final connected = args?['connected'] as bool? ?? false;
        final name = args?['name']?.toString() ?? "";
        if (mounted) {
          setState(() {
            _isBtConnected = connected;
            if (name.isNotEmpty) {
              _btDeviceName = name;
            } else if (!connected) {
              _btDeviceName = "Desconectado";
            }
          });
        }
        if (connected) {
          _log("✓ Bluetooth conectado: $_btDeviceName");
        } else {
          _log("[-] Bluetooth desconectado");
        }
      }
    });

    try {
      await _mediaChannel.invokeMethod('startMediaSession');
      if (mounted) setState(() => _isMediaActive = true);
      _log("✓ Servicio de control multimedia activo");
    } catch (e) {
      _log("[!] Error iniciando servicio multimedia: $e");
    }

    _refreshBluetoothDevice();
  }

  Future<void> _refreshBluetoothDevice() async {
    try {
      final res = await _mediaChannel
          .invokeMethod<Map<dynamic, dynamic>>('getConnectedBluetoothDevice');
      if (res != null && mounted) {
        final connected = res['connected'] as bool? ?? false;
        final name = res['name']?.toString() ?? "";
        setState(() {
          _isBtConnected = connected;
          if (name.isNotEmpty) _btDeviceName = name;
        });
      }
    } catch (_) {}
  }

  Future<void> _toggleMediaSession(bool enable) async {
    try {
      if (enable) {
        await _mediaChannel.invokeMethod('startMediaSession');
        if (mounted) setState(() => _isMediaActive = true);
        _log("✓ Control por auriculares activado");
      } else {
        await _mediaChannel.invokeMethod('stopMediaSession');
        if (mounted) setState(() => _isMediaActive = false);
        _log("[-] Control por auriculares desactivado");
      }
    } catch (e) {
      _log("[!] Error alternando servicio: $e");
    }
  }

  void _log(String msg) {
    if (!mounted) return;
    setState(() {
      final now = DateTime.now().toIso8601String().substring(11, 19);
      _logs.insert(0, "[$now] $msg");
      if (_logs.length > 50) _logs.removeLast();
    });
  }

  Future<void> _requestPermissions() async {
    if (Platform.isAndroid) {
      final statuses = await [
        Permission.bluetoothConnect,
        Permission.notification,
      ].request();

      final connOk = statuses[Permission.bluetoothConnect]?.isGranted ?? true;

      try {
        final isIgnored = await Permission.ignoreBatteryOptimizations.isGranted;
        if (!isIgnored) {
          final reqResult =
              await Permission.ignoreBatteryOptimizations.request();
          _batteryOptIgnored = reqResult.isGranted;
        } else {
          _batteryOptIgnored = true;
        }
      } catch (_) {}

      setState(() {
        _permissionsGranted = connOk;
      });
    } else {
      setState(() => _permissionsGranted = true);
    }
  }

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
      if (manual) _log("Buscando actualización...");

      final infoUri = _getPcHttpUri('/api/app-info');
      final client = HttpClient()
        ..badCertificateCallback = ((c, h, p) => true);
      client.connectionTimeout = const Duration(seconds: 4);

      final request = await client.getUrl(infoUri);
      final response =
          await request.close().timeout(const Duration(seconds: 4));

      if (response.statusCode != 200) {
        client.close();
        _isCheckingUpdate = false;
        return;
      }

      final responseBody = await response.transform(utf8.decoder).join();
      client.close();

      final data = jsonDecode(responseBody) as Map<String, dynamic>;
      final serverVersion = data['version']?.toString() ?? "";
      final sizeMb = data['size_mb']?.toString() ?? "";

      final hasUpdate =
          serverVersion.isNotEmpty && serverVersion != appVersion;

      if (!hasUpdate) {
        if (manual && mounted) {
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              backgroundColor: const Color(0xFF1E293B),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              title: const Row(
                children: [
                  Icon(Icons.check_circle, color: Color(0xFF10B981)),
                  SizedBox(width: 10),
                  Text("App al día"),
                ],
              ),
              content: Text(
                  "Ya tienes la versión más reciente instalada (v$appVersion)."),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text("Entendido"),
                ),
              ],
            ),
          );
        }
        _isCheckingUpdate = false;
        return;
      }

      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1E293B),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Row(
              children: [
                Icon(Icons.system_update, color: Color(0xFF38BDF8)),
                SizedBox(width: 10),
                Text("Nueva Versión"),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("Hay una nueva versión disponible: v$serverVersion",
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Text("Tamaño aproximado: $sizeMb",
                    style: const TextStyle(color: Colors.white70, fontSize: 13)),
                const SizedBox(height: 12),
                const Text(
                    "¿Deseas descargarla e instalarla automáticamente ahora?"),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text("Más tarde"),
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF38BDF8),
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
                icon: const Icon(Icons.download, size: 18),
                label: const Text("Actualizar"),
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
      if (manual && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("No se pudo verificar actualización: $e"),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } finally {
      _isCheckingUpdate = false;
    }
  }

  Future<void> _downloadAndInstallApk(String version, String sizeMb) async {
    try {
      if (Platform.isAndroid) {
        final canInstall =
            await _mediaChannel.invokeMethod<bool>('canInstallApk') ?? true;
        if (!canInstall) {
          if (mounted) {
            final grant = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                backgroundColor: const Color(0xFF1E293B),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
                title: const Text("Permiso de Instalación"),
                content: const Text(
                  "Para actualizar la app directamente, por favor autoriza a 'BT Presenter' a instalar aplicaciones.",
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text("Cancelar"),
                  ),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF38BDF8)),
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text("Autorizar",
                        style: TextStyle(color: Colors.black)),
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
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
                title: Row(
                  children: [
                    const Icon(Icons.downloading, color: Color(0xFF38BDF8)),
                    const SizedBox(width: 10),
                    Text("Descargando v$version"),
                  ],
                ),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LinearProgressIndicator(
                      value: progress > 0 ? progress : null,
                      backgroundColor: Colors.white10,
                      valueColor: const AlwaysStoppedAnimation<Color>(
                          Color(0xFF38BDF8)),
                    ),
                    const SizedBox(height: 14),
                    Text(statusText,
                        style: const TextStyle(
                            fontSize: 13, color: Colors.white70)),
                  ],
                ),
              );
            },
          );
        },
      );

      final cacheDir = await _mediaChannel.invokeMethod<String>('getCacheDir');
      final apkFile = File('$cacheDir/update.apk');
      if (await apkFile.exists()) {
        try {
          await apkFile.delete();
        } catch (_) {}
      }

      final client = HttpClient()
        ..badCertificateCallback = ((c, h, p) => true);
      HttpClientResponse response;
      try {
        final request = await client.getUrl(_getPcHttpUri('/BTPresenter.apk'));
        response = await request.close();
        if (response.statusCode != 200) {
          throw Exception("HTTP ${response.statusCode}");
        }
      } catch (pcErr) {
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
          Navigator.of(context, rootNavigator: true).pop();
        } catch (_) {}
      }

      await _mediaChannel
          .invokeMethod('installApk', {'filePath': apkFile.path});
    } catch (e) {
      if (mounted) {
        try {
          Navigator.of(context, rootNavigator: true).pop();
        } catch (_) {}
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text("Error actualizando: $e"),
              backgroundColor: Colors.redAccent),
        );
      }
    }
  }

  void _triggerHaptic(String action) {
    if (!_hapticEnabled) return;
    try {
      _mediaChannel.invokeMethod('vibrate', {'pattern': action});
      if (action == "forward") {
        HapticFeedback.mediumImpact();
      } else if (action == "back") {
        HapticFeedback.lightImpact();
        Future.delayed(const Duration(milliseconds: 100), () {
          HapticFeedback.lightImpact();
        });
      } else {
        HapticFeedback.heavyImpact();
      }
    } catch (_) {}
  }

  Future<void> _startDiscovery({bool manual = false}) async {
    if (_isDiscovering) return;
    setState(() => _isDiscovering = true);
    if (manual) _log("Buscando laptop en la red Wi-Fi...");

    try {
      _discoverySocket?.close();
      _discoverySocket =
          await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _discoverySocket!.broadcastEnabled = true;

      _discoverySocket!.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          final datagram = _discoverySocket?.receive();
          if (datagram != null) {
            try {
              final text = utf8.decode(datagram.data);
              final data = jsonDecode(text) as Map<String, dynamic>;
              final service = data['service']?.toString() ?? "";
              if (service == 'bt-presenter' ||
                  service == 'bt-clicker' ||
                  service == 'smartwatch-presenter' ||
                  service == 'airpresenter') {
                final ip = datagram.address.address;
                final port = data['port']?.toString() ?? "8888";
                final target = "$ip:$port";

                if (mounted) {
                  setState(() {
                    _pcController.text = target;
                    _isDiscovering = false;
                  });
                }
                _log("✓ ¡Laptop encontrada!: $target");
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

      final probe = utf8.encode("DISCOVER_PRESENTER");
      _discoverySocket!.send(probe, InternetAddress("255.255.255.255"), 8889);

      Future.delayed(const Duration(milliseconds: 700), () {
        if (_isDiscovering && _discoverySocket != null) {
          try {
            _discoverySocket!
                .send(probe, InternetAddress("255.255.255.255"), 8889);
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
            _log("[-] No se encontró la laptop automáticamente. Puedes ingresar la IP.");
          }
        }
      });
    } catch (e) {
      if (mounted) setState(() => _isDiscovering = false);
      if (manual) _log("[!] Error en búsqueda: $e");
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
        final scheme = target.contains(":8080") ? "ws" : "wss";
        final path = target.endsWith("/ws") ? target : "$target/ws";
        uri = Uri.parse("$scheme://$path");
      }

      _channel = IOWebSocketChannel.connect(
        uri,
        pingInterval: const Duration(seconds: 5),
      );

      _channel!.stream.listen(
        (message) {
          if (!_isWsConnected) {
            setState(() => _isWsConnected = true);
            _log("✓ Conectado a la laptop con éxito");
            _checkForUpdates(manual: false);
          }
          try {
            final data = jsonDecode(message.toString());
            if (data['action'] == 'forward') {
              _triggerAction("forward", "⏩ Diapositiva Siguiente",
                  "Avanzar presentación", const Color(0xFF38BDF8));
            } else if (data['action'] == 'back') {
              _triggerAction("back", "⏪ Diapositiva Anterior",
                  "Retroceder presentación", const Color(0xFFF43F5E));
            } else if (data['action'] == 'play_pause') {
              _triggerAction("play_pause", "⏸️ Telón Negro (Pausa)",
                  "Ocultar o pausar pantalla", const Color(0xFFA855F7));
            }
          } catch (_) {}
        },
        onDone: () {
          setState(() => _isWsConnected = false);
          _wsReconnectTimer =
              Timer(const Duration(seconds: 3), _connectWebSocket);
        },
        onError: (err) {
          setState(() => _isWsConnected = false);
          _wsReconnectTimer =
              Timer(const Duration(seconds: 3), _connectWebSocket);
        },
      );

      _sendWs("hello");
      setState(() => _isWsConnected = true);
      _checkForUpdates(manual: false);
    } catch (e) {
      setState(() => _isWsConnected = false);
      _wsReconnectTimer =
          Timer(const Duration(seconds: 3), _connectWebSocket);
    }
  }

  void _sendWs(String event) {
    if (_channel != null) {
      try {
        _channel!.sink.add(jsonEncode({
          "event": event,
          "timestamp": DateTime.now().millisecondsSinceEpoch,
        }));
      } catch (_) {}
    }
  }

  void _triggerAction(
      String action, String title, String subtitle, Color color) {
    _triggerHaptic(action);
    _sendWs(action);
    setState(() {
      _actionCount++;
      _lastActionText = title;
      _lastActionSub = subtitle;
      _flashColor = color.withValues(alpha: 0.15);
    });
    Future.delayed(const Duration(milliseconds: 600), () {
      if (mounted) setState(() => _flashColor = Colors.transparent);
    });
  }

  void _showHelpGuide() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                "¿Cómo usar BT Presenter?",
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.white),
              ),
              const SizedBox(height: 16),
              _buildHelpRow(
                Icons.headphones,
                "Con tus Auriculares Bluetooth",
                "• 1 Toque (Siguiente canción) ➔ Pasa a la siguiente diapositiva\n• 2 Toques (Canción anterior) ➔ Vuelve atrás\n• Pausa ➔ Pone la pantalla en negro (ideal para Canva)",
                const Color(0xFF38BDF8),
              ),
              const SizedBox(height: 12),
              _buildHelpRow(
                Icons.watch,
                "Con tu Smartwatch",
                "Gira la corona o pulsa los controles de música de tu reloj para cambiar de diapositiva sin tocar nada más.",
                const Color(0xFF10B981),
              ),
              const SizedBox(height: 12),
              _buildHelpRow(
                Icons.phone_android,
                "Con este Teléfono",
                "También puedes usar los botones grandes en la pantalla para controlar tu presentación como un clicker profesional.",
                const Color(0xFFA855F7),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF38BDF8),
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text("¡Entendido!"),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildHelpRow(
      IconData icon, String title, String description, Color color) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: color, size: 22),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                      color: Colors.white)),
              const SizedBox(height: 2),
              Text(description,
                  style:
                      const TextStyle(fontSize: 12, color: Colors.white70, height: 1.3)),
            ],
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _discoveryTimeoutTimer?.cancel();
    _discoverySocket?.close();
    _wsReconnectTimer?.cancel();
    _channel?.sink.close();
    _mediaChannel.invokeMethod('stopMediaSession').catchError((_) {});
    super.dispose();
  }

  Widget _buildSplashScreen() {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 104,
              height: 104,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF38BDF8).withValues(alpha: 0.25),
                    blurRadius: 32,
                    spreadRadius: 4,
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(22),
                child:
                    Image.asset('assets/images/mascot.png', fit: BoxFit.cover),
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'BT Presenter',
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.bold,
                color: Colors.white,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Control de diapositivas universal',
              style: TextStyle(
                fontSize: 14,
                color: Color(0xFF94A3B8),
              ),
            ),
            const SizedBox(height: 36),
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF38BDF8)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSparkyAssistantCard() {
    String message;
    Color statusColor;

    if (_isWsConnected && _isBtConnected) {
      message =
          "¡Todo listo! Ya puedes pasar diapositivas usando tus auriculares ($_btDeviceName) o con los botones abajo.";
      statusColor = const Color(0xFF10B981);
    } else if (_isWsConnected && !_isBtConnected) {
      message =
          "Tu laptop está conectada. Puedes usar los botones de la app o conectar auriculares/reloj por Bluetooth.";
      statusColor = const Color(0xFF38BDF8);
    } else if (!_isWsConnected && _isBtConnected) {
      message =
          "Tus auriculares están listos. Pulsa 'Buscar mi Laptop' para conectarte a tu presentación.";
      statusColor = const Color(0xFFF59E0B);
    } else {
      message =
          "¡Bienvenido! Asegúrate de estar en el mismo Wi-Fi que tu laptop y pulsa 'Buscar mi Laptop'.";
      statusColor = const Color(0xFF94A3B8);
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: statusColor.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: const Color(0xFF0F172A),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.asset('assets/images/mascot.png', fit: BoxFit.cover),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: statusColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    const Text(
                      "Asistente Sparky",
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  message,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFFCBD5E1),
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLaptopCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: _isWsConnected
                      ? const Color(0xFF10B981).withValues(alpha: 0.15)
                      : const Color(0xFFF59E0B).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.laptop_mac,
                  color: _isWsConnected
                      ? const Color(0xFF10B981)
                      : const Color(0xFFF59E0B),
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Laptop de Presentación",
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        color: Colors.white,
                      ),
                    ),
                    Text(
                      _isWsConnected
                          ? "Conectada (${_pcController.text})"
                          : "Sin conexión a la laptop",
                      style: TextStyle(
                        fontSize: 12,
                        color: _isWsConnected
                            ? const Color(0xFF10B981)
                            : const Color(0xFF94A3B8),
                      ),
                    ),
                  ],
                ),
              ),
              if (_isWsConnected)
                IconButton(
                  icon: const Icon(Icons.sync,
                      size: 20, color: Color(0xFF38BDF8)),
                  tooltip: 'Reconectar',
                  onPressed: _connectWebSocket,
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (!_isWsConnected)
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0284C7),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                icon: _isDiscovering
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.radar, size: 20),
                label: Text(
                  _isDiscovering
                      ? "Buscando laptop en la red..."
                      : "🔍 Buscar mi Laptop",
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                onPressed: _isDiscovering ? null : () => _startDiscovery(manual: true),
              ),
            ),
          const SizedBox(height: 6),
          Center(
            child: TextButton(
              onPressed: () {
                setState(() => _showManualIp = !_showManualIp);
              },
              child: Text(
                _showManualIp
                    ? "Ocultar configuración manual"
                    : "⚙️ Escribir dirección IP manualmente",
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF94A3B8),
                ),
              ),
            ),
          ),
          if (_showManualIp)
            Container(
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFF334155)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _pcController,
                      style: const TextStyle(fontSize: 13, color: Colors.white),
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        hintText: "Ejemplo: 192.168.1.15:8888",
                        hintStyle:
                            TextStyle(color: Colors.white24, fontSize: 12),
                      ),
                    ),
                  ),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF38BDF8),
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                    onPressed: _connectWebSocket,
                    child: const Text("Conectar"),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildControlDeviceCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: _isBtConnected
                  ? const Color(0xFF10B981).withValues(alpha: 0.15)
                  : Colors.white10,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              _isBtConnected ? Icons.headphones : Icons.bluetooth,
              color: _isBtConnected
                  ? const Color(0xFF10B981)
                  : const Color(0xFF94A3B8),
              size: 22,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "Dispositivo de Control",
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _isBtConnected
                      ? "Conectado: $_btDeviceName"
                      : "Sin auriculares o reloj conectados",
                  style: TextStyle(
                    fontSize: 12,
                    color: _isBtConnected
                        ? const Color(0xFF10B981)
                        : const Color(0xFF94A3B8),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh,
                size: 20, color: Color(0xFF38BDF8)),
            tooltip: 'Verificar Bluetooth',
            onPressed: () {
              _refreshBluetoothDevice();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(_isBtConnected
                      ? "Dispositivo detectado: $_btDeviceName"
                      : "No hay auriculares Bluetooth conectados aún"),
                  duration: const Duration(seconds: 2),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildPresentationRemoteCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
            decoration: BoxDecoration(
              color: _flashColor == Colors.transparent
                  ? const Color(0xFF0F172A)
                  : _flashColor,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _flashColor == Colors.transparent
                    ? const Color(0xFF334155)
                    : const Color(0xFF38BDF8),
                width: 1.5,
              ),
            ),
            child: Column(
              children: [
                Text(
                  _lastActionText,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 4),
                Text(
                  _lastActionSub,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF94A3B8),
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: SizedBox(
                  height: 54,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      backgroundColor: const Color(0xFF0F172A),
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Color(0xFF334155)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: const Icon(Icons.arrow_back_ios_new, size: 16),
                    label: const Text(
                      "Anterior",
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    onPressed: () {
                      _triggerAction(
                        "back",
                        "⏪ Diapositiva Anterior",
                        "Presionado en pantalla",
                        const Color(0xFFF43F5E),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 54,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    backgroundColor: const Color(0xFF3B0764).withValues(alpha: 0.3),
                    foregroundColor: const Color(0xFFD8B4FE),
                    side: const BorderSide(color: Color(0xFFA855F7)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                  ),
                  onPressed: () {
                    _triggerAction(
                      "play_pause",
                      "⏸️ Telón Negro",
                      "Ocultar diapositiva en pantalla",
                      const Color(0xFFA855F7),
                    );
                  },
                  child: const Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.pause, size: 18),
                      Text("Telón", style: TextStyle(fontSize: 10)),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 4,
                child: SizedBox(
                  height: 54,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0284C7),
                      foregroundColor: Colors.white,
                      elevation: 2,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: const Icon(Icons.arrow_forward_ios, size: 18),
                    label: const Text(
                      "Siguiente",
                      style:
                          TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                    ),
                    onPressed: () {
                      _triggerAction(
                        "forward",
                        "⏩ Diapositiva Siguiente",
                        "Presionado en pantalla",
                        const Color(0xFF38BDF8),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPreferencesCard() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.vibration, color: Color(0xFF38BDF8)),
            title: const Text("Vibración al pulsar",
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            subtitle: const Text("Siente una vibración al cambiar de página",
                style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8))),
            value: _hapticEnabled,
            activeTrackColor: const Color(0xFF38BDF8),
            onChanged: (val) {
              setState(() => _hapticEnabled = val);
              if (val) _triggerHaptic("forward");
            },
          ),
          const Divider(color: Color(0xFF334155), height: 1),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.headphones, color: Color(0xFF10B981)),
            title: const Text("Control con Auriculares",
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            subtitle: const Text(
                "Permite pasar diapositivas con el botón de tus audífonos",
                style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8))),
            value: _isMediaActive,
            activeTrackColor: const Color(0xFF10B981),
            onChanged: _toggleMediaSession,
          ),
        ],
      ),
    );
  }

  Widget _buildActivityLogSection() {
    return Column(
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () {
            setState(() => _showActivityLog = !_showActivityLog);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 4.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  _showActivityLog
                      ? Icons.keyboard_arrow_up
                      : Icons.keyboard_arrow_down,
                  color: const Color(0xFF94A3B8),
                  size: 20,
                ),
                const SizedBox(width: 6),
                Text(
                  _showActivityLog
                      ? "Ocultar registro de actividad"
                      : "Ver registro de actividad ($_actionCount eventos)",
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF94A3B8),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_showActivityLog)
          Container(
            height: 120,
            margin: const EdgeInsets.only(top: 6),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF334155)),
            ),
            child: _logs.isEmpty
                ? const Center(
                    child: Text(
                      "Sin eventos aún",
                      style: TextStyle(fontSize: 11, color: Colors.white30),
                    ),
                  )
                : ListView.builder(
                    itemCount: _logs.length,
                    itemBuilder: (context, i) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2.0),
                        child: Text(
                          _logs[i],
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xFF94A3B8),
                          ),
                        ),
                      );
                    },
                  ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_showSplash) {
      return _buildSplashScreen();
    }

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F172A),
        elevation: 0,
        titleSpacing: 16,
        title: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.asset('assets/images/app_logo.png'),
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'BT Presenter',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                Text(
                  _isWsConnected
                      ? "Laptop conectada"
                      : "Sin conexión a la laptop",
                  style: TextStyle(
                    fontSize: 11,
                    color: _isWsConnected
                        ? const Color(0xFF10B981)
                        : const Color(0xFFF59E0B),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline, color: Color(0xFF94A3B8)),
            tooltip: 'Cómo usar',
            onPressed: _showHelpGuide,
          ),
          IconButton(
            icon: const Icon(Icons.system_update_alt,
                size: 20, color: Color(0xFF38BDF8)),
            tooltip: 'Buscar actualización',
            onPressed: () => _checkForUpdates(manual: true),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!_permissionsGranted && Platform.isAndroid)
                Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF450A0A).withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFEF4444).withValues(alpha: 0.5)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.bluetooth_disabled, color: Color(0xFFEF4444), size: 20),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          "Se requiere permiso Bluetooth para detectar tus dispositivos.",
                          style: TextStyle(fontSize: 12, color: Color(0xFFFCA5A5)),
                        ),
                      ),
                      TextButton(
                        onPressed: _requestPermissions,
                        child: const Text("Conceder", style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFFEF4444))),
                      ),
                    ],
                  ),
                ),
              if (!_batteryOptIgnored && Platform.isAndroid)
                Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF451A03).withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFF59E0B).withValues(alpha: 0.5)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.battery_alert, color: Color(0xFFF59E0B), size: 20),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          "Permite que la app funcione sin pausas con la pantalla apagada.",
                          style: TextStyle(fontSize: 12, color: Color(0xFFFDE68A)),
                        ),
                      ),
                      TextButton(
                        onPressed: () async {
                          await Permission.ignoreBatteryOptimizations.request();
                          final ok = await Permission.ignoreBatteryOptimizations.isGranted;
                          if (mounted) setState(() => _batteryOptIgnored = ok);
                        },
                        child: const Text("Activar", style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFFF59E0B))),
                      ),
                    ],
                  ),
                ),
              _buildSparkyAssistantCard(),
              const SizedBox(height: 12),
              _buildLaptopCard(),
              const SizedBox(height: 12),
              _buildControlDeviceCard(),
              const SizedBox(height: 12),
              _buildPresentationRemoteCard(),
              const SizedBox(height: 12),
              _buildPreferencesCard(),
              const SizedBox(height: 12),
              _buildActivityLogSection(),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}
