#!/usr/bin/env python3
"""
Fase 3: Daemon de Control Remoto de Diapositivas vía BLE (Smartwatch)
Intercepta la firma de bytes configurada y simula eventos de teclado (KEY_RIGHT/KEY_PAGEDOWN)
usando evdev/uinput para compatibilidad universal en Linux (Wayland y X11).
"""
import asyncio
import argparse
import datetime
import json
import os
import sys
import time
import re

try:
    import evdev
    from evdev import ecodes
except ImportError:
    print("[X] Error: 'evdev' no está instalado. Ejecuta 'pip install evdev'.")
    sys.exit(1)

from bleak import BleakClient, BleakScanner

CONFIG_FILE = "config.json"

SUPPORTED_KEYS = {
    "RIGHT": ecodes.KEY_RIGHT,
    "PAGEDOWN": ecodes.KEY_PAGEDOWN,
    "PAGEUP": ecodes.KEY_PAGEUP,
    "LEFT": ecodes.KEY_LEFT,
    "SPACE": ecodes.KEY_SPACE,
    "ENTER": ecodes.KEY_ENTER,
    "F5": ecodes.KEY_F5,
    "ESC": ecodes.KEY_ESC,
}


def load_config():
    if os.path.exists(CONFIG_FILE):
        try:
            with open(CONFIG_FILE, "r") as f:
                return json.load(f)
        except Exception:
            pass
    return {}


class VirtualClicker:
    def __init__(self, key_name: str = "RIGHT", key_back: str = "LEFT"):
        self.key_name = key_name.upper()
        self.key_back = key_back.upper()
        self.keycode_forward = SUPPORTED_KEYS.get(self.key_name, ecodes.KEY_RIGHT)
        self.keycode_back = SUPPORTED_KEYS.get(self.key_back, ecodes.KEY_LEFT)
        capabilities = {
            ecodes.EV_KEY: list(SUPPORTED_KEYS.values())
        }
        self.uinput = evdev.UInput(events=capabilities, name="Smartwatch-BLE-Presenter")
        print(f"[✓] Teclado virtual uinput inicializado: 'Smartwatch-BLE-Presenter'")
        print(f"    - Toque simple:      Avanzar    ➜ [{self.key_name}]")
        print(f"    - Doble toque (tap): Retroceder ➜ [{self.key_back}]")

    def emit_forward(self):
        self._press_key(self.keycode_forward)

    def emit_back(self):
        self._press_key(self.keycode_back)

    def _press_key(self, keycode):
        self.uinput.write(ecodes.EV_KEY, keycode, 1)  # Key down
        self.uinput.syn()
        time.sleep(0.04)
        self.uinput.write(ecodes.EV_KEY, keycode, 0)  # Key up
        self.uinput.syn()

    def close(self):
        try:
            self.uinput.close()
        except Exception:
            pass


class SmartwatchRemoteDaemon:
    def __init__(self, address: str, char_uuid: str, trigger_hex: str,
                 key_name: str = "RIGHT", key_back: str = "LEFT",
                 debounce_ms: int = 250, enable_double_tap: bool = True, double_tap_ms: int = 500):
        self.address = address
        self.char_uuid = char_uuid.split()[0].strip().lower() if char_uuid else ""
        self.trigger_hex = trigger_hex.replace(" ", "").upper()
        self.debounce_sec = debounce_ms / 1000.0
        self.enable_double_tap = enable_double_tap
        self.double_tap_sec = double_tap_ms / 1000.0
        self.last_press_time = 0.0
        self.last_sequence = None
        self.clicker = VirtualClicker(key_name=key_name, key_back=key_back)
        self.is_running = True
        self.connected = False
        self.client = None
        self.pending_forward_task = None

    def _on_notification(self, sender, data: bytearray):
        current_time = time.time()
        hex_received = data.hex().upper()
        sender_uuid = str(sender).lower()

        # Comprobar si coincide la firma de bytes
        is_match = False
        if self.trigger_hex:
            if hex_received == self.trigger_hex or hex_received.startswith(self.trigger_hex):
                is_match = True
            elif re.search(self.trigger_hex, hex_received):
                is_match = True

        # Reconocimiento intrínseco del protocolo Laxasfit/HryFine (Header DF 00 06, Cmd 0C, Subcmd 01)
        if not is_match and len(data) >= 6 and data[0] == 0xDF and data[4] == 0x0C and data[5] == 0x01:
            is_match = True

        # Si no hay trigger definido, cualquier notificación de la característica cuenta
        if not self.trigger_hex:
            is_match = True

        now_str = datetime.datetime.now().strftime("%H:%M:%S.%f")[:-3]

        if is_match:
            # Extracción del contador de secuencia del reloj si corresponde a protocolo Laxasfit
            seq_num = data[6] if len(data) >= 7 and data[0] == 0xDF and data[4] == 0x0C else None

            # 1. Filtro estricto por número de secuencia repetido (descartar ráfagas del mismo toque físico)
            if seq_num is not None and self.last_sequence is not None and seq_num == self.last_sequence:
                return

            # 2. Filtro temporal anti-rebote (debounce)
            elapsed = current_time - self.last_press_time
            if elapsed < self.debounce_sec:
                return

            self.last_press_time = current_time
            self.last_sequence = seq_num

            if self.enable_double_tap:
                # Si ya hay un primer toque esperando ventana de doble toque:
                if self.pending_forward_task and not self.pending_forward_task.done():
                    self.pending_forward_task.cancel()
                    self.pending_forward_task = None
                    self.clicker.emit_back()
                    print(f"[{now_str}] ⏪ DOBLE TOQUE! ➜ Tecla [{self.clicker.key_back}] enviada (Retroceder diapositiva)")
                else:
                    async def delayed_forward(seq=seq_num, t_str=now_str):
                        try:
                            await asyncio.sleep(self.double_tap_sec)
                            self.clicker.emit_forward()
                            seq_info = f" (Seq: {seq})" if seq is not None else ""
                            print(f"[{t_str}] ⏩ TOQUE SIMPLE{seq_info}! ➜ Tecla [{self.clicker.key_name}] enviada (Avanzar diapositiva)")
                        except asyncio.CancelledError:
                            pass
                        finally:
                            self.pending_forward_task = None

                    self.pending_forward_task = asyncio.create_task(delayed_forward())
            else:
                self.clicker.emit_forward()
                seq_info = f" (Seq: {seq_num})" if seq_num is not None else ""
                print(f"[{now_str}] ⏩ TOQUE SIMPLE{seq_info}! ➜ Tecla [{self.clicker.key_name}] enviada (Avanzar diapositiva)")
        else:
            print(f"[{now_str}] ℹ️  Paquete no coincidente recibido: {data.hex(' ').upper()}")

    def _on_disconnected(self, client):
        self.connected = False
        now_str = datetime.datetime.now().strftime("%H:%M:%S")
        print(f"[{now_str}] ⚠️ Desconectado de {self.address}. Reintentando conexión en segundo plano...")

    async def run(self):
        print("\n" + "=" * 70)
        print("  INICIANDO DAEMON DE CONTROL REMOTO SMARTWATCH")
        print("=" * 70)
        print(f"  Dirección MAC:       {self.address}")
        print(f"  Característica UUID: {self.char_uuid or 'Auto-detectar (todas las notificaciones)'}")
        print(f"  Firma HEX Trigger:   {self.trigger_hex or 'Cualquier paquete'}")
        print(f"  Tecla a simular:     {self.clicker.key_name}")
        print(f"  Debounce:            {self.debounce_sec * 1000:.0f} ms")
        print("=" * 70)
        print("[*] Presiona Ctrl+C para detener el daemon.\n")

        backoff_delay = 2

        while self.is_running:
            try:
                print(f"[{datetime.datetime.now().strftime('%H:%M:%S')}] Conectando con {self.address}...")
                self.client = BleakClient(self.address, disconnected_callback=self._on_disconnected, timeout=12.0)
                await self.client.connect()

                if self.client.is_connected:
                    self.connected = True
                    backoff_delay = 2
                    print(f"[✓] Conexión establecida exitosamente.")

                    clean_target = self.char_uuid.split()[0].lower() if self.char_uuid else ""
                    subscribed_chars = []
                    for service in self.client.services:
                        for char in service.characteristics:
                            if "notify" in char.properties or "indicate" in char.properties:
                                if not clean_target or clean_target in char.uuid.lower() or char.uuid.lower() in clean_target:
                                    try:
                                        await self.client.start_notify(char.uuid, self._on_notification)
                                        subscribed_chars.append(char.uuid)
                                    except Exception as e:
                                        print(f"[!] No se pudo suscribir a {char.uuid}: {e}")

                    if not subscribed_chars:
                        print(f"[X] No se pudo encontrar {self.char_uuid}. Suscribiendo a todas las características notify disponibles...")
                        for service in self.client.services:
                            for char in service.characteristics:
                                if "notify" in char.properties or "indicate" in char.properties:
                                    try:
                                        await self.client.start_notify(char.uuid, self._on_notification)
                                        subscribed_chars.append(char.uuid)
                                    except Exception:
                                        pass

                    # Tarea de Keep-Alive en segundo plano para evitar desconexiones por inactividad del reloj
                    async def keepalive_worker():
                        batt_uuid = "00002a19-0000-1000-8000-00805f9b34fb"
                        while self.is_running and self.client and self.client.is_connected:
                            try:
                                await asyncio.sleep(4.0)
                                if self.client and self.client.is_connected:
                                    await self.client.read_gatt_char(batt_uuid)
                            except Exception:
                                break

                    keepalive_task = asyncio.create_task(keepalive_worker())
                    try:
                        # Mantener loop de conexión activo
                        while self.is_running and self.client.is_connected:
                            await asyncio.sleep(0.5)
                    finally:
                        keepalive_task.cancel()

            except asyncio.CancelledError:
                break
            except Exception as e:
                now_str = datetime.datetime.now().strftime("%H:%M:%S")
                print(f"[{now_str}] [!] Reloj en reposo ({e}). Reconectando en 1s... (toca la pantalla si está apagada)")
                await asyncio.sleep(1.0)
                backoff_delay = 1.0

        # Limpieza
        if self.client and self.client.is_connected:
            try:
                await self.client.disconnect()
            except Exception:
                pass
        self.clicker.close()
        print("\n[+] Daemon finalizado limpiamente.")


def main():
    parser = argparse.ArgumentParser(description="Daemon de control remoto de diapositivas BLE")
    parser.add_argument("-a", "--address", type=str, help="Dirección MAC del smartwatch")
    parser.add_argument("-c", "--char", type=str, help="UUID de la característica notify")
    parser.add_argument("-t", "--trigger", type=str, help="Firma hexadecimal a interceptar")
    parser.add_argument("-k", "--key", type=str, default=None, choices=list(SUPPORTED_KEYS.keys()), help="Tecla avanzar (def: RIGHT)")
    parser.add_argument("-kb", "--key-back", type=str, default=None, choices=list(SUPPORTED_KEYS.keys()), help="Tecla retroceder (def: LEFT)")
    parser.add_argument("-d", "--debounce", type=int, default=None, help="Anti-rebote en ms (def: 250)")
    parser.add_argument("--no-double-tap", action="store_true", help="Desactivar detección de doble toque para retroceder")
    parser.add_argument("--double-tap-ms", type=int, default=None, help="Ventana de tiempo para doble toque en ms (def: 500)")
    args = parser.parse_args()

    cfg = load_config()
    address = args.address or cfg.get("device_address")
    char_uuid = args.char or cfg.get("notify_char_uuid")
    trigger_hex = args.trigger or cfg.get("trigger_hex")
    key_name = args.key or cfg.get("key", "RIGHT")
    key_back = args.key_back or cfg.get("key_back", "LEFT")
    debounce_ms = args.debounce or cfg.get("debounce_ms", 250)
    enable_double_tap = not args.no_double_tap if args.no_double_tap else cfg.get("enable_double_tap", True)
    double_tap_ms = args.double_tap_ms or cfg.get("double_tap_ms", 500)

    if not address:
        print("[!] Error: No se especificó la dirección MAC.")
        print("    Usa 'python3 scanner.py -s' para configurarla o usa '--address <MAC>'.")
        sys.exit(1)

    daemon = SmartwatchRemoteDaemon(
        address=address,
        char_uuid=char_uuid,
        trigger_hex=trigger_hex,
        key_name=key_name,
        key_back=key_back,
        debounce_ms=debounce_ms,
        enable_double_tap=enable_double_tap,
        double_tap_ms=double_tap_ms
    )

    try:
        asyncio.run(daemon.run())
    except KeyboardInterrupt:
        print("\n[+] Interrupción por usuario recibida.")


if __name__ == "__main__":
    main()
