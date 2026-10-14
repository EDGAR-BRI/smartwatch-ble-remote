import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:iconify_flutter/iconify_flutter.dart';
import 'package:iconify_flutter/icons/material_symbols.dart';
import 'package:iconify_flutter/icons/ri.dart';
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
const String appVersion = "1.1.2+16";
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
  final TextEditingController _pcController =
      TextEditingController(text: defaultPcUrl);

  WebSocketChannel? _channel;
  Timer? _wsReconnectTimer;

  bool _isBtConnected = false;
  String _btDeviceName = "Sin dispositivo";
  bool _isWsConnected = false;
  bool _isMediaActive = false;
  bool _isCheckingUpdate = false;
  bool _hapticEnabled = true;
  bool _isDiscovering = false;
  bool _showSplash = true;
  RawDatagramSocket? _discoverySocket;
  Timer? _discoveryTimeoutTimer;

  String _lastActionTitle = "Listo para presentar";
  String _lastActionSub = "Toca tus audífonos, reloj o los botones";
  String _lastActionIcon = Ri.slideshow_line;
  Color _lastActionColor = const Color(0xFF38BDF8);
  Color _flashColor = Colors.transparent;
  int _lastActionTimestamp = 0;
  final List<String> _logs = [];

  @override
  void initState() {
    super.initState();
    _initApp();
  }

  Future<void> _initApp() async {
    // Splash screen limpio de 1.0 segundo
    Future.delayed(const Duration(milliseconds: 1000), () {
      if (mounted) setState(() => _showSplash = false);
    });

    try {
      await WakelockPlus.enable();
    } catch (_) {}

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
            if (_btDeviceName == "Sin dispositivo") {
              _btDeviceName = "Dispositivo Activo";
            }
          });
        }
        if (action == "forward") {
          _triggerAction(
            "forward",
            "Siguiente Diapositiva",
            "Disparo desde auriculares / reloj",
            const Color(0xFF38BDF8),
            Ri.skip_forward_fill,
          );
        } else if (action == "back") {
          _triggerAction(
            "back",
            "Diapositiva Anterior",
            "Disparo desde auriculares / reloj",
            const Color(0xFFF43F5E),
            Ri.skip_back_fill,
          );
        } else if (action == "play_pause") {
          _triggerAction(
            "play_pause",
            "Telón Negro (Pausa)",
            "Disparo desde auriculares / reloj",
            const Color(0xFFA855F7),
            Ri.pause_circle_fill,
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
              _btDeviceName = "Sin dispositivo";
            }
          });
        }
        _log(connected
            ? "✓ Bluetooth conectado: $_btDeviceName"
            : "[-] Bluetooth desconectado");
      }
    });

    try {
      await _mediaChannel.invokeMethod('startMediaSession');
      if (mounted) setState(() => _isMediaActive = true);
      _log("✓ Escucha de auriculares activa");
    } catch (_) {}

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
      } else {
        await _mediaChannel.invokeMethod('stopMediaSession');
        if (mounted) setState(() => _isMediaActive = false);
      }
    } catch (_) {}
  }

  void _log(String msg) {
    if (!mounted) return;
    setState(() {
      final now = DateTime.now().toIso8601String().substring(11, 19);
      _logs.insert(0, "[$now] $msg");
      if (_logs.length > 40) _logs.removeLast();
    });
  }

  Future<void> _requestPermissions() async {
    if (Platform.isAndroid) {
      await [
        Permission.bluetoothConnect,
        Permission.notification,
      ].request();

      try {
        final isIgnored = await Permission.ignoreBatteryOptimizations.isGranted;
        if (!isIgnored) {
          await Permission.ignoreBatteryOptimizations.request();
        }
      } catch (_) {}
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

  bool _isNewerVersion(String currentVer, String newVer) {
    try {
      final cleanCur =
          currentVer.replaceFirst(RegExp(r'^v'), '').split('+')[0].trim();
      final cleanNew =
          newVer.replaceFirst(RegExp(r'^v'), '').split('+')[0].trim();

      final curParts =
          cleanCur.split('.').map((e) => int.tryParse(e) ?? 0).toList();
      final newParts =
          cleanNew.split('.').map((e) => int.tryParse(e) ?? 0).toList();

      while (curParts.length < 3) {
        curParts.add(0);
      }
      while (newParts.length < 3) {
        newParts.add(0);
      }

      for (int i = 0; i < 3; i++) {
        if (newParts[i] > curParts[i]) return true;
        if (newParts[i] < curParts[i]) return false;
      }

      int curBuild = 0;
      int newBuild = 0;
      if (currentVer.contains('+')) {
        curBuild = int.tryParse(currentVer.split('+')[1]) ?? 0;
      }
      if (newVer.contains('+')) {
        newBuild = int.tryParse(newVer.split('+')[1]) ?? 0;
      }
      return newBuild > curBuild;
    } catch (_) {
      return newVer != currentVer && newVer.isNotEmpty;
    }
  }

  Future<void> _checkForUpdates({bool manual = false}) async {
    if (_isCheckingUpdate) return;
    _isCheckingUpdate = true;

    BuildContext? progressDialogContext;
    if (manual && mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (dialogCtx) {
          progressDialogContext = dialogCtx;
          return const AlertDialog(
            backgroundColor: Color(0xFF1E293B),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(16)),
            ),
            content: Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Color(0xFF38BDF8),
                    ),
                  ),
                  SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      "Buscando actualizaciones...",
                      style: TextStyle(color: Colors.white, fontSize: 14),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    }

    String serverVersion = "";
    String sizeMb = "";
    String downloadUrl = "";

    try {
      // 1. Probar servidor local si está configurado
      try {
        final infoUri = _getPcHttpUri('/api/app-info');
        final client = HttpClient()
          ..badCertificateCallback = ((c, h, p) => true);
        client.connectionTimeout = const Duration(seconds: 3);

        final request = await client.getUrl(infoUri);
        final response =
            await request.close().timeout(const Duration(seconds: 3));

        if (response.statusCode == 200) {
          final responseBody = await response.transform(utf8.decoder).join();
          final data = jsonDecode(responseBody) as Map<String, dynamic>;
          serverVersion = data['version']?.toString() ?? "";
          sizeMb = data['size_mb']?.toString() ?? "";
          downloadUrl = _getPcHttpUri('/BTPresenter.apk').toString();
        }
        client.close();
      } catch (_) {}

      // 2. Si no hubo respuesta local, consultar GitHub Releases
      if (serverVersion.isEmpty) {
        try {
          final client = HttpClient();
          client.connectionTimeout = const Duration(seconds: 4);
          final ghUri = Uri.parse(
              "https://api.github.com/repos/EDGAR-BRI/smartwatch-ble-remote/releases/latest");
          final request = await client.getUrl(ghUri);
          request.headers.set("User-Agent", "BTPresenter");
          final response =
              await request.close().timeout(const Duration(seconds: 4));

          if (response.statusCode == 200) {
            final body = await response.transform(utf8.decoder).join();
            final data = jsonDecode(body) as Map<String, dynamic>;
            final tag = data['tag_name']?.toString() ?? "";
            serverVersion = tag.replaceFirst(RegExp(r'^v'), '');
            final assets = data['assets'] as List<dynamic>? ?? [];
            for (final a in assets) {
              final name = a['name']?.toString() ?? "";
              if (name == 'BTPresenter.apk' ||
                  (name.startsWith('BTPresenter-') && name.endsWith('.apk'))) {
                final sizeBytes = a['size'] as int? ?? 0;
                if (sizeBytes > 0) {
                  sizeMb =
                      "${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB";
                }
                downloadUrl = a['browser_download_url']?.toString() ?? "";
                break;
              }
            }
          }
          client.close();
        } catch (_) {}
      }

      // Cerrar diálogo de progreso si estaba abierto
      if (progressDialogContext != null && progressDialogContext!.mounted) {
        Navigator.pop(progressDialogContext!);
      }

      final hasUpdate = serverVersion.isNotEmpty &&
          _isNewerVersion(appVersion, serverVersion);

      if (hasUpdate) {
        if (mounted) {
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              backgroundColor: const Color(0xFF1E293B),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              title: const Row(
                children: [
                  Iconify(Ri.download_2_line, color: Color(0xFF38BDF8), size: 22),
                  SizedBox(width: 10),
                  Text(
                    "Nueva Versión",
                    style: TextStyle(
                        fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                ],
              ),
              content: Text(
                "Hay una actualización disponible (v$serverVersion${sizeMb.isNotEmpty ? ' - $sizeMb' : ''}).\n\n¿Deseas descargar e instalar la nueva versión ahora?",
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text("Luego",
                      style: TextStyle(color: Colors.white54)),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF38BDF8),
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: () {
                    Navigator.pop(ctx);
                    _downloadAndInstallApk(serverVersion, sizeMb,
                        overrideUrl:
                            downloadUrl.isNotEmpty ? downloadUrl : null);
                  },
                  child: const Text("Actualizar Ahora",
                      style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          );
        }
      } else if (manual) {
        if (mounted) {
          if (serverVersion.isEmpty) {
            showDialog(
              context: context,
              builder: (ctx) => AlertDialog(
                backgroundColor: const Color(0xFF1E293B),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
                title: const Row(
                  children: [
                    Iconify(Ri.wifi_off_line, color: Color(0xFFF59E0B), size: 22),
                    SizedBox(width: 10),
                    Text("Sin Conexión",
                        style: TextStyle(
                            fontWeight: FontWeight.bold, color: Colors.white)),
                  ],
                ),
                content: const Text(
                  "No se pudo comprobar si hay actualizaciones.\n\nVerifica que estés en la misma red Wi-Fi que tu laptop o que tengas conexión a internet.",
                  style: TextStyle(color: Colors.white70, fontSize: 14),
                ),
                actions: [
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF334155),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text("Entendido",
                        style: TextStyle(color: Colors.white)),
                  ),
                ],
              ),
            );
          } else {
            showDialog(
              context: context,
              builder: (ctx) => AlertDialog(
                backgroundColor: const Color(0xFF1E293B),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
                title: const Row(
                  children: [
                    Iconify(Ri.checkbox_circle_line,
                        color: Color(0xFF10B981), size: 22),
                    SizedBox(width: 10),
                    Text("Aplicación al Día",
                        style: TextStyle(
                            fontWeight: FontWeight.bold, color: Colors.white)),
                  ],
                ),
                content: Text(
                  "Ya tienes instalada la versión más reciente (v$appVersion).\n\nNo hay actualizaciones pendientes por el momento.",
                  style: const TextStyle(color: Colors.white70, fontSize: 14),
                ),
                actions: [
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF10B981),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text("Aceptar",
                        style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            );
          }
        }
      }
    } catch (_) {
      if (progressDialogContext != null && progressDialogContext!.mounted) {
        Navigator.pop(progressDialogContext!);
      }
    } finally {
      _isCheckingUpdate = false;
    }
  }

  Future<void> _downloadAndInstallApk(String version, String sizeMb,
      {String? overrideUrl}) async {
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
                title: const Text("Permiso requerido"),
                content: const Text(
                    "Por favor autoriza la instalación de actualizaciones directas."),
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
                title: Text(
                    "Descargando v$version${sizeMb.isNotEmpty ? ' ($sizeMb)' : ''}",
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LinearProgressIndicator(
                      value: progress > 0 ? progress : null,
                      backgroundColor: Colors.white10,
                      valueColor: const AlwaysStoppedAnimation<Color>(
                          Color(0xFF38BDF8)),
                    ),
                    const SizedBox(height: 12),
                    Text("${(progress * 100).toInt()}% completado",
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
        final targetUri = (overrideUrl != null && overrideUrl.isNotEmpty)
            ? Uri.parse(overrideUrl)
            : _getPcHttpUri('/BTPresenter.apk');
        final request = await client.getUrl(targetUri);
        response = await request.close();
        if (response.statusCode != 200) {
          throw Exception("HTTP ${response.statusCode}");
        }
      } catch (_) {
        final request = await client.getUrl(Uri.parse(githubLatestApkUrl));
        response = await request.close();
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
            content: Text("Error al descargar actualización: $e"),
            backgroundColor: Colors.redAccent,
          ),
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
        Future.delayed(const Duration(milliseconds: 90), () {
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
                _log("✓ Laptop detectada: $target");
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

      _discoveryTimeoutTimer?.cancel();
      _discoveryTimeoutTimer = Timer(const Duration(seconds: 4), () {
        if (mounted && _isDiscovering) {
          setState(() => _isDiscovering = false);
          _discoverySocket?.close();
          _discoverySocket = null;
          if (manual) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                    "No se detectó laptop automáticamente. Revisa que estén en el mismo Wi-Fi."),
                duration: Duration(seconds: 3),
              ),
            );
          }
        }
      });
    } catch (e) {
      if (mounted) setState(() => _isDiscovering = false);
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
            _log("✓ Conectado a la laptop");
            _checkForUpdates(manual: false);
          }
          try {
            final data = jsonDecode(message.toString());
            if (data['action'] == 'forward') {
              _triggerAction("forward", "Siguiente Diapositiva",
                  "Recibido de la laptop", const Color(0xFF38BDF8), Ri.skip_forward_fill,
                  sendWs: false);
            } else if (data['action'] == 'back') {
              _triggerAction("back", "Diapositiva Anterior",
                  "Recibido de la laptop", const Color(0xFFF43F5E), Ri.skip_back_fill,
                  sendWs: false);
            } else if (data['action'] == 'play_pause') {
              _triggerAction("play_pause", "Telón Negro",
                  "Recibido de la laptop", const Color(0xFFA855F7), Ri.pause_circle_fill,
                  sendWs: false);
            }
          } catch (_) {}
        },
        onDone: () {
          setState(() => _isWsConnected = false);
          _wsReconnectTimer =
              Timer(const Duration(seconds: 3), _connectWebSocket);
        },
        onError: (_) {
          setState(() => _isWsConnected = false);
          _wsReconnectTimer =
              Timer(const Duration(seconds: 3), _connectWebSocket);
        },
      );

      _sendWs("hello");
      setState(() => _isWsConnected = true);
      _checkForUpdates(manual: false);
    } catch (_) {
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
      String action, String title, String subtitle, Color color, String icon,
      {bool sendWs = true}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastActionTimestamp < 120) return;
    _lastActionTimestamp = now;

    _triggerHaptic(action);
    if (sendWs) {
      _sendWs(action);
      _log("Enviado -> $title");
    } else {
      _log("Recibido <- $title");
    }

    setState(() {
      _lastActionIcon = icon;
      _lastActionColor = color;
      _lastActionTitle = title;
      _lastActionSub = subtitle;
      _flashColor = color.withValues(alpha: 0.2);
    });
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) setState(() => _flashColor = Colors.transparent);
    });
  }

  void _openConsoleSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setConsoleState) {
            return Container(
              height: MediaQuery.of(context).size.height * 0.75,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 44,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      const Iconify(Ri.terminal_box_line,
                          color: Color(0xFF38BDF8), size: 22),
                      const SizedBox(width: 10),
                      const Text(
                        "Consola de Actividad",
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Iconify(Ri.delete_bin_line,
                            color: Colors.white60, size: 20),
                        tooltip: "Limpiar consola",
                        onPressed: () {
                          setState(() => _logs.clear());
                          setConsoleState(() {});
                        },
                      ),
                      IconButton(
                        icon: const Iconify(Ri.file_copy_line,
                            color: Colors.white60, size: 20),
                        tooltip: "Copiar logs",
                        onPressed: () {
                          if (_logs.isEmpty) return;
                          Clipboard.setData(
                              ClipboardData(text: _logs.reversed.join('\n')));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text("Logs copiados al portapapeles"),
                              duration: Duration(seconds: 2),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    "${_logs.length} eventos registrados (tiempo real)",
                    style: const TextStyle(fontSize: 12, color: Colors.white54),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF020617),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: const Color(0xFF1E293B)),
                      ),
                      child: _logs.isEmpty
                          ? const Center(
                              child: Text(
                                "No hay eventos registrados aún.\nLas pulsaciones y conexiones aparecerán aquí.",
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    color: Colors.white38, fontSize: 13),
                              ),
                            )
                          : ListView.builder(
                              itemCount: _logs.length,
                              itemBuilder: (context, index) {
                                final log = _logs[index];
                                Color textColor = const Color(0xFFCBD5E1);
                                if (log.contains("Enviado")) {
                                  textColor = const Color(0xFF38BDF8);
                                } else if (log.contains("Recibido") ||
                                    log.contains("✓")) {
                                  textColor = const Color(0xFF10B981);
                                } else if (log.contains("[-]")) {
                                  textColor = const Color(0xFFF59E0B);
                                }
                                return Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 3),
                                  child: Text(
                                    log,
                                    style: TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 12,
                                      color: textColor,
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _openSettingsSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 16,
                bottom: MediaQuery.of(context).viewInsets.bottom + 24,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 44,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    "Configuración y Conexión",
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Botón Buscar Laptop en la red
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF0284C7),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      icon: _isDiscovering
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Iconify(Ri.wifi_line,
                              color: Colors.white, size: 20),
                      label: Text(
                        _isDiscovering
                            ? "Buscando Laptop..."
                            : "Buscar Laptop en la Red",
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 14),
                      ),
                      onPressed: _isDiscovering
                          ? null
                          : () {
                              Navigator.pop(ctx);
                              _startDiscovery(manual: true);
                            },
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Laptop IP input
                  const Text(
                    "Dirección IP de tu Laptop",
                    style: TextStyle(fontSize: 13, color: Colors.white70),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F172A),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFF334155)),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _pcController,
                            style: const TextStyle(
                                fontSize: 14, color: Colors.white),
                            decoration: const InputDecoration(
                              border: InputBorder.none,
                              hintText: "Ej: 192.168.1.15:8888",
                              hintStyle: TextStyle(color: Colors.white30),
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: () {
                            _connectWebSocket();
                            Navigator.pop(ctx);
                          },
                          child: const Text("Guardar",
                              style: TextStyle(fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Switches
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    secondary: const Iconify(
                        MaterialSymbols.vibration_rounded,
                        color: Color(0xFF38BDF8),
                        size: 22),
                    title: const Text("Vibración al pulsar",
                        style: TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600)),
                    subtitle: const Text("Siente un toque táctil al cambiar",
                        style: TextStyle(fontSize: 12, color: Colors.white60)),
                    value: _hapticEnabled,
                    activeTrackColor: const Color(0xFF38BDF8),
                    onChanged: (val) {
                      setState(() => _hapticEnabled = val);
                      setSheetState(() {});
                      if (val) _triggerHaptic("forward");
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    secondary: const Iconify(Ri.headphone_line,
                        color: Color(0xFF10B981), size: 22),
                    title: const Text("Control con Auriculares",
                        style: TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600)),
                    subtitle: const Text(
                        "Pasa diapositivas con el botón de tus audífonos",
                        style: TextStyle(fontSize: 12, color: Colors.white60)),
                    value: _isMediaActive,
                    activeTrackColor: const Color(0xFF10B981),
                    onChanged: (val) {
                      _toggleMediaSession(val);
                      setSheetState(() {});
                    },
                  ),
                  const Divider(color: Color(0xFF334155), height: 20),

                  // Actions row
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: Color(0xFF334155)),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10)),
                          ),
                          icon: const Iconify(Ri.download_2_line,
                              size: 18, color: Color(0xFF38BDF8)),
                          label: const Text("Actualizaciones",
                              style: TextStyle(
                                  color: Colors.white, fontSize: 13)),
                          onPressed: () {
                            Navigator.pop(ctx);
                            Future.delayed(const Duration(milliseconds: 250),
                                () {
                              if (mounted) _checkForUpdates(manual: true);
                            });
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: Color(0xFF334155)),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10)),
                          ),
                          icon: const Iconify(Ri.question_line,
                              size: 18, color: Color(0xFF10B981)),
                          label: const Text("¿Cómo usar?",
                              style: TextStyle(
                                  color: Colors.white, fontSize: 13)),
                          onPressed: () {
                            Navigator.pop(ctx);
                            Future.delayed(const Duration(milliseconds: 250),
                                () {
                              if (mounted) _showHelpGuide();
                            });
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Color(0xFF334155)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                      icon: const Iconify(Ri.terminal_box_line,
                          size: 18, color: Color(0xFF38BDF8)),
                      label: const Text("Consola de Actividad",
                          style: TextStyle(
                              color: Colors.white, fontSize: 13)),
                      onPressed: () {
                        Navigator.pop(ctx);
                        Future.delayed(const Duration(milliseconds: 250), () {
                          if (mounted) _openConsoleSheet();
                        });
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _showHelpGuide() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.all(22.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 44,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                "¿Cómo pasar diapositivas?",
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.white),
              ),
              const SizedBox(height: 18),
              _buildHelpRow(
                MaterialSymbols.touch_app_rounded,
                "En esta Pantalla",
                "Pulsa el botón grande azul para avanzar. El botón izquierdo retrocede y 'Telón' oculta la diapositiva.",
                const Color(0xFF38BDF8),
              ),
              const SizedBox(height: 14),
              _buildHelpRow(
                Ri.headphone_fill,
                "Con tus Auriculares Bluetooth",
                "• 1 toque (siguiente pista) -> Avanzar\n• 2 toques (pista anterior) -> Retroceder\n• Pausa -> Telón negro en Canva",
                const Color(0xFF10B981),
              ),
              const SizedBox(height: 14),
              _buildHelpRow(
                MaterialSymbols.watch_rounded,
                "Con tu Smartwatch",
                "Gira la corona digital o usa los botones de música para controlar la presentación.",
                const Color(0xFFA855F7),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF38BDF8),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text("Entendido",
                      style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildHelpRow(
      String icon, String title, String description, Color color) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Iconify(icon, color: color, size: 22),
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
                  style: const TextStyle(
                      fontSize: 12, color: Colors.white70, height: 1.3)),
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
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF38BDF8).withValues(alpha: 0.25),
                    blurRadius: 30,
                    spreadRadius: 4,
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(22),
                child: Image.asset('assets/images/mascot.png', fit: BoxFit.cover),
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'BT Presenter',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Control de presentaciones universal',
              style: TextStyle(fontSize: 13, color: Color(0xFF94A3B8)),
            ),
          ],
        ),
      ),
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
            const Text(
              'BT Presenter',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ],
        ),
        actions: [
          // Estado de conexión Laptop
          GestureDetector(
            onTap: _isWsConnected
                ? _openSettingsSheet
                : () => _startDiscovery(manual: true),
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 12),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: _isWsConnected
                    ? const Color(0xFF10B981).withValues(alpha: 0.15)
                    : const Color(0xFFF59E0B).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: _isWsConnected
                      ? const Color(0xFF10B981).withValues(alpha: 0.4)
                      : const Color(0xFFF59E0B).withValues(alpha: 0.4),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Iconify(
                    _isWsConnected ? Ri.checkbox_circle_line : Ri.wifi_line,
                    color: _isWsConnected
                        ? const Color(0xFF10B981)
                        : const Color(0xFFF59E0B),
                    size: 14,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _isWsConnected
                        ? "Laptop Conectada"
                        : (_isDiscovering ? "Buscando..." : "Buscar Laptop"),
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: _isWsConnected
                          ? const Color(0xFF10B981)
                          : const Color(0xFFF59E0B),
                    ),
                  ),
                ],
              ),
            ),
          ),
          IconButton(
            icon: const Iconify(Ri.terminal_box_line, color: Colors.white70, size: 20),
            tooltip: 'Consola de Actividad',
            onPressed: _openConsoleSheet,
          ),
          IconButton(
            icon: const Iconify(Ri.settings_3_line, color: Colors.white70, size: 20),
            tooltip: 'Configuración',
            onPressed: _openSettingsSheet,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18.0, vertical: 12.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 1. Visor de Acción (Hero Feedback)
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
                decoration: BoxDecoration(
                  color: _flashColor == Colors.transparent
                      ? const Color(0xFF1E293B)
                      : _flashColor,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: _flashColor == Colors.transparent
                        ? const Color(0xFF334155)
                        : const Color(0xFF38BDF8),
                    width: 1.5,
                  ),
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Iconify(_lastActionIcon, color: _lastActionColor, size: 22),
                        const SizedBox(width: 8),
                        Text(
                          _lastActionTitle,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _lastActionSub,
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFFCBD5E1),
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 14),

              // Botón Prominente para Buscar Laptop si está desconectada
              if (!_isWsConnected) ...[
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1E293B),
                      foregroundColor: const Color(0xFF38BDF8),
                      side: const BorderSide(
                          color: Color(0xFF0284C7), width: 1.5),
                      padding: const EdgeInsets.symmetric(
                          vertical: 14, horizontal: 16),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                      elevation: 3,
                    ),
                    icon: _isDiscovering
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: Color(0xFF38BDF8),
                            ),
                          )
                        : const Iconify(Ri.wifi_line,
                            color: Color(0xFF38BDF8), size: 20),
                    label: Text(
                      _isDiscovering
                          ? "Buscando laptop en la red..."
                          : "Buscar Laptop en la Red",
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    onPressed: _isDiscovering
                        ? null
                        : () => _startDiscovery(manual: true),
                  ),
                ),
                const SizedBox(height: 12),
              ],

              // 2. Gran Botón SIGUIENTE (Ocupa la mayor parte del clicker)
              Expanded(
                flex: 5,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0284C7), // Sky 600
                    foregroundColor: Colors.white,
                    elevation: 4,
                    shadowColor: const Color(0xFF0284C7).withValues(alpha: 0.5),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(22),
                    ),
                  ),
                  onPressed: () {
                    _triggerAction(
                      "forward",
                      "Siguiente Diapositiva",
                      "Pulsado en la pantalla",
                      const Color(0xFF38BDF8),
                      Ri.skip_forward_fill,
                    );
                  },
                  child: const Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Iconify(Ri.skip_forward_fill,
                          size: 44, color: Colors.white),
                      SizedBox(height: 10),
                      Text(
                        "SIGUIENTE",
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 12),

              // 3. Fila de Botones Secundarios: ANTERIOR y TELÓN NEGRO
              Expanded(
                flex: 2,
                child: Row(
                  children: [
                    // Botón Anterior
                    Expanded(
                      flex: 3,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          backgroundColor: const Color(0xFF1E293B),
                          foregroundColor: Colors.white,
                          side: const BorderSide(
                              color: Color(0xFF334155), width: 1.5),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        icon: const Iconify(Ri.skip_back_fill,
                            size: 18, color: Colors.white),
                        label: const Text(
                          "Anterior",
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                        onPressed: () {
                          _triggerAction(
                            "back",
                            "Diapositiva Anterior",
                            "Pulsado en la pantalla",
                            const Color(0xFFF43F5E),
                            Ri.skip_back_fill,
                          );
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    // Botón Telón Negro (Canva / PowerPoint)
                    Expanded(
                      flex: 2,
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          backgroundColor:
                              const Color(0xFF581C87).withValues(alpha: 0.35),
                          foregroundColor: const Color(0xFFE9D5FF),
                          side: const BorderSide(
                              color: Color(0xFFA855F7), width: 1.5),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        onPressed: () {
                          _triggerAction(
                            "play_pause",
                            "Telón Negro",
                            "Pantalla en pausa / oculta",
                            const Color(0xFFA855F7),
                            Ri.pause_circle_fill,
                          );
                        },
                        child: const Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Iconify(Ri.pause_circle_fill,
                                size: 22, color: Color(0xFFE9D5FF)),
                            SizedBox(height: 2),
                            Text(
                              "Telón",
                              style: TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 14),

              // 4. Barra Inferior Dispositivo Bluetooth (Minimalista y Táctil)
              GestureDetector(
                onTap: _showHelpGuide,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E293B),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Iconify(
                        _isBtConnected ? Ri.headphone_fill : Ri.bluetooth_line,
                        color: _isBtConnected
                            ? const Color(0xFF10B981)
                            : const Color(0xFF94A3B8),
                        size: 18,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _isBtConnected
                              ? "Control: $_btDeviceName"
                              : "Toca aquí para ver cómo usar audífonos o reloj",
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: _isBtConnected
                                ? Colors.white
                                : const Color(0xFF94A3B8),
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 6),
                      const Iconify(Ri.question_line,
                          size: 16, color: Colors.white38),
                      if (_hapticEnabled) ...[
                        const SizedBox(width: 8),
                        const Iconify(MaterialSymbols.vibration_rounded,
                            size: 16, color: Colors.white38),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
