#!/usr/bin/env python3
"""
Servidor Web Bridge (Opción 1): Puente Web Bluetooth entre Teléfono y PC Linux
Recibe eventos de disparo desde Google Chrome móvil y simula pulsaciones
de diapositivas en Canva/Navegador usando evdev/uinput.
"""
import asyncio
import datetime
import json
import os
import socket
import ssl
import sys
import time
from aiohttp import web

try:
    import evdev
    from evdev import ecodes
except ImportError:
    print("[X] Error: 'evdev' no está instalado. Ejecuta 'pip install evdev'.")
    sys.exit(1)

SUPPORTED_KEYS = {
    "RIGHT": ecodes.KEY_RIGHT,
    "LEFT": ecodes.KEY_LEFT,
    "PAGEDOWN": ecodes.KEY_PAGEDOWN,
    "PAGEUP": ecodes.KEY_PAGEUP,
    "SPACE": ecodes.KEY_SPACE,
    "U": ecodes.KEY_U,
}


class VirtualClicker:
    def __init__(self, key_forward="RIGHT", key_back="LEFT", key_pause="U"):
        self.code_forward = SUPPORTED_KEYS.get(key_forward.upper(), ecodes.KEY_RIGHT)
        self.code_back = SUPPORTED_KEYS.get(key_back.upper(), ecodes.KEY_LEFT)
        self.code_pause = SUPPORTED_KEYS.get(key_pause.upper(), ecodes.KEY_U)
        capabilities = {ecodes.EV_KEY: list(SUPPORTED_KEYS.values())}
        self.uinput = evdev.UInput(events=capabilities, name="Smartwatch-Phone-Bridge")
        print(f"[✓] Teclado virtual uinput listo: 'Smartwatch-Phone-Bridge'")
        print(f"    - Avanzar:    [{key_forward}]")
        print(f"    - Retroceder: [{key_back}]")
        print(f"    - Pausa (U):  [{key_pause}]")

    def emit(self, keycode):
        self.uinput.write(ecodes.EV_KEY, keycode, 1)
        self.uinput.syn()
        time.sleep(0.04)
        self.uinput.write(ecodes.EV_KEY, keycode, 0)
        self.uinput.syn()

    def forward(self):
        self.emit(self.code_forward)

    def back(self):
        self.emit(self.code_back)

    def pause(self):
        self.emit(self.code_pause)


def get_local_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(('8.8.8.8', 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return '127.0.0.1'


GITHUB_REPO = "EDGAR-BRI/smartwatch-ble-remote"
GITHUB_LATEST_RELEASE_APK_URL = f"https://github.com/{GITHUB_REPO}/releases/latest/download/SmartwatchPresenter.apk"
GITHUB_LATEST_RELEASE_PAGE = f"https://github.com/{GITHUB_REPO}/releases/latest"


def get_app_version_info():
    base_dir = os.path.dirname(__file__)
    pubspec_path = os.path.join(base_dir, "mobile_app", "pubspec.yaml")
    apk_path = os.path.join(
        base_dir, "mobile_app", "build", "app", "outputs", "flutter-apk", "app-release.apk"
    )

    version = "1.0.1+2"
    version_name = "1.0.1"
    build_number = "2"
    if os.path.exists(pubspec_path):
        try:
            with open(pubspec_path, "r", encoding="utf-8") as f:
                for line in f:
                    stripped = line.strip()
                    if stripped.startswith("version:"):
                        v_part = stripped.split("version:")[1].strip()
                        version = v_part
                        if "+" in v_part:
                            parts = v_part.split("+")
                            version_name = parts[0]
                            build_number = parts[1]
                        else:
                            version_name = v_part
                            build_number = ""
                        break
        except Exception:
            pass

    apk_exists = os.path.exists(apk_path)
    size_mb = "--"
    build_time = "No disponible"
    mtime = 0

    if apk_exists:
        try:
            stat = os.stat(apk_path)
            size_mb = f"{stat.st_size / (1024 * 1024):.1f} MB"
            mtime_dt = datetime.datetime.fromtimestamp(stat.st_mtime)
            build_time = mtime_dt.strftime("%d/%m/%Y %H:%M:%S")
            mtime = stat.st_mtime
        except Exception:
            pass

    return {
        "version": version,
        "version_name": version_name,
        "build_number": build_number,
        "apk_exists": apk_exists,
        "size_mb": size_mb,
        "build_time": build_time,
        "mtime": mtime,
        "filename": f"SmartwatchPresenter-v{version_name}.apk",
        "github_apk_url": GITHUB_LATEST_RELEASE_APK_URL,
        "github_release_url": GITHUB_LATEST_RELEASE_PAGE,
    }


class BridgeServer:
    def __init__(self, double_tap_ms=450):
        self.clicker = VirtualClicker()
        self.double_tap_sec = double_tap_ms / 1000.0
        self.last_press_time = 0.0
        self.last_sequence = None
        self.pending_forward_task = None
        self.connected_sockets = set()

    async def _broadcast(self, data):
        for s in list(self.connected_sockets):
            try:
                await s.send_json(data)
            except Exception:
                pass

    async def handle_index(self, request):
        index_path = os.path.join(os.path.dirname(__file__), "static", "index.html")
        if os.path.exists(index_path):
            return web.FileResponse(index_path)
        return web.Response(text="index.html no encontrado", status=404)

    async def handle_ws(self, request):
        ws = web.WebSocketResponse()
        await ws.prepare(request)
        self.connected_sockets.add(ws)
        client_ip = request.remote
        print(f"\n[+] Cliente conectado por WebSocket desde {client_ip} (Total: {len(self.connected_sockets)})")

        try:
            async for msg in ws:
                if msg.type == web.WSMsgType.TEXT:
                    data = json.loads(msg.data)
                    event_type = data.get("event")

                    if event_type == "shutter":
                        seq = data.get("sequence", -1)
                        await self._process_shutter(seq, ws)
                    elif event_type == "forward":
                        self.clicker.forward()
                        now_str = datetime.datetime.now().strftime("%H:%M:%S")
                        print(f"[{now_str}] ⏩ Click manual: Avanzar")
                        await self._broadcast({"action": "forward"})
                    elif event_type == "back":
                        self.clicker.back()
                        now_str = datetime.datetime.now().strftime("%H:%M:%S")
                        print(f"[{now_str}] ⏪ Click manual: Retroceder")
                        await self._broadcast({"action": "back"})
                    elif event_type in ("play_pause", "pause"):
                        self.clicker.pause()
                        now_str = datetime.datetime.now().strftime("%H:%M:%S")
                        print(f"[{now_str}] ⏯️ Pausa / Tecla U pulsada (Canva Telón)")
                        await self._broadcast({"action": "play_pause"})

        finally:
            self.connected_sockets.discard(ws)
            print(f"[-] Cliente desconectado de {client_ip} (Restantes: {len(self.connected_sockets)})")
        return ws

    async def _process_shutter(self, seq_num, ws):
        current_time = time.time()
        now_str = datetime.datetime.now().strftime("%H:%M:%S.%f")[:-3]

        # Descartar ráfagas repetidas con la misma secuencia
        if seq_num != -1 and self.last_sequence is not None and seq_num == self.last_sequence:
            return

        self.last_sequence = seq_num

        # Comprobar doble toque
        if self.pending_forward_task and not self.pending_forward_task.done():
            # Llega 2do toque antes de que venza la ventana -> DOBLE TOQUE!
            self.pending_forward_task.cancel()
            self.pending_forward_task = None
            self.clicker.back()
            print(f"[{now_str}] ⏪ DOBLE TOQUE desde reloj (Seq: {seq_num}) ➜ Retroceder")
            await self._broadcast({"action": "back"})
        else:
            # 1er toque: programar avance diferido para dar tiempo al doble toque
            async def delayed_forward(s=seq_num, t_str=now_str):
                try:
                    await asyncio.sleep(self.double_tap_sec)
                    self.clicker.forward()
                    print(f"[{t_str}] ⏩ TOQUE SIMPLE desde reloj (Seq: {s}) ➜ Avanzar")
                    await self._broadcast({"action": "forward"})
                except asyncio.CancelledError:
                    pass
                finally:
                    self.pending_forward_task = None

            self.pending_forward_task = asyncio.create_task(delayed_forward())


    async def handle_app_info(self, request):
        info = get_app_version_info()
        return web.json_response(info)

    async def handle_download(self, request):
        info = get_app_version_info()
        apk_path = os.path.join(
            os.path.dirname(__file__),
            "mobile_app", "build", "app", "outputs", "flutter-apk", "app-release.apk"
        )
        if os.path.exists(apk_path):
            filename = info["filename"]
            return web.FileResponse(apk_path, headers={
                "Content-Disposition": f'attachment; filename="{filename}"',
                "X-App-Version": info["version"],
                "Cache-Control": "no-cache, no-store, must-revalidate",
                "Pragma": "no-cache",
                "Expires": "0",
            })
        # Si la laptop no tiene el APK compilado localmente, redirige automáticamente a GitHub Releases
        raise web.HTTPFound(GITHUB_LATEST_RELEASE_APK_URL)


class DiscoveryProtocol(asyncio.DatagramProtocol):
    def __init__(self, local_ip, port=8888, http_port=8080):
        self.local_ip = local_ip
        self.port = port
        self.http_port = http_port
        self.transport = None

    def connection_made(self, transport):
        self.transport = transport
        sock = transport.get_extra_info("socket")
        if sock:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)

    def datagram_received(self, data, addr):
        try:
            msg = data.decode("utf-8", errors="ignore").strip()
            if "DISCOVER" in msg or "SMARTWATCH" in msg or "PRESENTER" in msg:
                info = get_app_version_info()
                response = json.dumps({
                    "service": "smartwatch-presenter",
                    "ip": self.local_ip,
                    "port": self.port,
                    "http_port": self.http_port,
                    "version": info.get("version", "1.0.0"),
                    "name": socket.gethostname(),
                }).encode("utf-8")
                self.transport.sendto(response, addr)
        except Exception:
            pass


async def broadcast_beacon(transport, local_ip, port=8888, http_port=8080):
    while True:
        try:
            info = get_app_version_info()
            beacon = json.dumps({
                "service": "smartwatch-presenter",
                "ip": local_ip,
                "port": port,
                "http_port": http_port,
                "version": info.get("version", "1.0.0"),
                "name": socket.gethostname(),
            }).encode("utf-8")
            transport.sendto(beacon, ("255.255.255.255", 8889))
        except Exception:
            pass
        await asyncio.sleep(3)


async def main():
    bridge = BridgeServer()
    app = web.Application()
    app.router.add_get("/", bridge.handle_index)
    app.router.add_static("/static", os.path.join(os.path.dirname(__file__), "static"))
    app.router.add_get("/ws", bridge.handle_ws)
    app.router.add_get("/app.apk", bridge.handle_download)
    app.router.add_get("/download", bridge.handle_download)
    app.router.add_get("/api/app-info", bridge.handle_app_info)
    app.router.add_get("/version", bridge.handle_app_info)

    runner = web.AppRunner(app)
    await runner.setup()

    # 1. Servidor HTTP (para localhost con adb reverse)
    site_http = web.TCPSite(runner, "0.0.0.0", 8080)
    await site_http.start()

    # 2. Servidor HTTPS en puerto 8888 (abierto y permitido en UFW)
    ssl_context = None
    cert_file = os.path.join(os.path.dirname(__file__), "cert.pem")
    key_file = os.path.join(os.path.dirname(__file__), "key.pem")
    if os.path.exists(cert_file) and os.path.exists(key_file):
        ssl_context = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
        ssl_context.load_cert_chain(cert_file, key_file)
        site_https = web.TCPSite(runner, "0.0.0.0", 8888, ssl_context=ssl_context)
        await site_https.start()

    local_ip = get_local_ip()

    # 3. Servidor de Auto-descubrimiento UDP (Puerto 8889)
    loop = asyncio.get_running_loop()
    udp_transport, _ = await loop.create_datagram_endpoint(
        lambda: DiscoveryProtocol(local_ip, 8888, 8080),
        local_addr=("0.0.0.0", 8889),
        allow_broadcast=True,
    )
    beacon_task = asyncio.create_task(broadcast_beacon(udp_transport, local_ip, 8888, 8080))
    info = get_app_version_info()
    print("\n" + "=" * 70)
    print("  PUENTE WEB BLUETOOTH ACTIVO (SMARTWATCH ➔ TELÉFONO ➔ PC)")
    print("=" * 70)
    print(f"  📦 Versión App Android: v{info['version']} ({info['size_mb']})")
    print(f"  🕒 Compilación: {info['build_time']}")
    print(f"  🐙 GitHub Releases: {GITHUB_LATEST_RELEASE_APK_URL}")
    print(f"  🌐 IP detectada en tu red actual: {local_ip}")
    print("-" * 70)
    print("Elige cualquiera de las dos formas de abrirlo en tu celular:")
    print("")
    print("▶ MÉTODO A (Por Wi-Fi sin cables):")
    print("  1. En Google Chrome de tu teléfono para descargar la app o usar web:")
    print(f"     👉 https://{local_ip}:8888")
    print("  2. En la App Android 'Smartwatch Presenter':")
    print(f"     Escribe en el campo de IP: {local_ip}:8888 y pulsa 🔄")
    print("")
    print("▶ MÉTODO B (Por cable USB / ADB sin depender de Wi-Fi):")
    print("  1. Conecta el teléfono por USB con 'Depuración USB' activa.")
    print("  2. En tu terminal corre: adb reverse tcp:8080 tcp:8080")
    print("  3. En la app o navegador usa: localhost:8080")
    print("=" * 70)
    print("[*] Presiona Ctrl+C para detener el servidor.\n")

    try:
        while True:
            await asyncio.sleep(3600)
    except (asyncio.CancelledError, KeyboardInterrupt):
        pass
    finally:
        try:
            beacon_task.cancel()
            udp_transport.close()
        except Exception:
            pass
        await runner.cleanup()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n[+] Servidor web finalizado.")
