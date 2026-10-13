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
}


class VirtualClicker:
    def __init__(self, key_forward="RIGHT", key_back="LEFT"):
        self.code_forward = SUPPORTED_KEYS.get(key_forward.upper(), ecodes.KEY_RIGHT)
        self.code_back = SUPPORTED_KEYS.get(key_back.upper(), ecodes.KEY_LEFT)
        capabilities = {ecodes.EV_KEY: list(SUPPORTED_KEYS.values())}
        self.uinput = evdev.UInput(events=capabilities, name="Smartwatch-Phone-Bridge")
        print(f"[✓] Teclado virtual uinput listo: 'Smartwatch-Phone-Bridge'")
        print(f"    - Avanzar:    [{key_forward}]")
        print(f"    - Retroceder: [{key_back}]")

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


class BridgeServer:
    def __init__(self, double_tap_ms=450):
        self.clicker = VirtualClicker()
        self.double_tap_sec = double_tap_ms / 1000.0
        self.last_press_time = 0.0
        self.last_sequence = None
        self.pending_forward_task = None
        self.connected_sockets = set()

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
        print(f"\n[+] Teléfono conectado por WebSocket desde {client_ip}")

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
                        await ws.send_json({"action": "forward"})
                    elif event_type == "back":
                        self.clicker.back()
                        now_str = datetime.datetime.now().strftime("%H:%M:%S")
                        print(f"[{now_str}] ⏪ Click manual: Retroceder")
                        await ws.send_json({"action": "back"})

        finally:
            self.connected_sockets.remove(ws)
            print(f"[-] Teléfono desconectado de {client_ip}")
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
            try:
                await ws.send_json({"action": "back"})
            except Exception:
                pass
        else:
            # 1er toque: programar avance diferido para dar tiempo al doble toque
            async def delayed_forward(s=seq_num, t_str=now_str):
                try:
                    await asyncio.sleep(self.double_tap_sec)
                    self.clicker.forward()
                    print(f"[{t_str}] ⏩ TOQUE SIMPLE desde reloj (Seq: {s}) ➜ Avanzar")
                    try:
                        await ws.send_json({"action": "forward"})
                    except Exception:
                        pass
                except asyncio.CancelledError:
                    pass
                finally:
                    self.pending_forward_task = None

            self.pending_forward_task = asyncio.create_task(delayed_forward())


    async def handle_download(self, request):
        apk_path = os.path.join(
            os.path.dirname(__file__),
            "mobile_app", "build", "app", "outputs", "flutter-apk", "app-release.apk"
        )
        if os.path.exists(apk_path):
            return web.FileResponse(apk_path, headers={
                "Content-Disposition": 'attachment; filename="SmartwatchPresenter.apk"'
            })
        return web.Response(text="APK no encontrado", status=404)


async def main():
    bridge = BridgeServer()
    app = web.Application()
    app.router.add_get("/", bridge.handle_index)
    app.router.add_get("/ws", bridge.handle_ws)
    app.router.add_get("/app.apk", bridge.handle_download)
    app.router.add_get("/download", bridge.handle_download)

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

    print("\n" + "=" * 70)
    print("  PUENTE WEB BLUETOOTH ACTIVO (SMARTWATCH ➔ TELÉFONO ➔ PC)")
    print("=" * 70)
    print("Elige cualquiera de las dos formas de abrirlo en tu celular:")
    print("")
    print("▶ MÉTODO A (Por Wi-Fi sin cables - Puerto 8888 libre de firewall):")
    print("  En Google Chrome en tu teléfono, entra a:")
    print("  👉 https://10.0.0.3:8888")
    print("  (Acepta la advertencia de certificado autofirmado: 'Avanzado' ➔ 'Acceder').")
    print("")
    print("▶ MÉTODO B (Por cable USB / ADB sin advertencias):")
    print("  1. Conecta el teléfono por USB con 'Depuración USB' activa.")
    print("  2. En tu terminal corre: adb reverse tcp:8080 tcp:8080")
    print("  3. En Chrome de tu celular abre: http://localhost:8080")
    print("=" * 70)
    print("[*] Presiona 'Conectar Smartwatch' en la página de tu celular.")
    print("[*] Presiona Ctrl+C para detener el servidor.\n")

    try:
        while True:
            await asyncio.sleep(3600)
    except (asyncio.CancelledError, KeyboardInterrupt):
        pass
    finally:
        await runner.cleanup()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n[+] Servidor web finalizado.")
