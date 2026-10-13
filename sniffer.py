#!/usr/bin/env python3
"""
Fase 2: Sniffer e Inspección GATT para Smartwatch BLE
Descubre servicios, se suscribe a características Notify/Indicate y
captura en tiempo real los paquetes hexadecimales emitidos por el reloj.
"""
import asyncio
import argparse
import datetime
import json
import os
import sys
from bleak import BleakClient, BleakScanner

CONFIG_FILE = "config.json"


def load_config():
    if os.path.exists(CONFIG_FILE):
        try:
            with open(CONFIG_FILE, "r") as f:
                return json.load(f)
        except Exception:
            pass
    return {}


def save_trigger_config(char_uuid: str, hex_pattern: str):
    config = load_config()
    clean_uuid = char_uuid.split()[0].strip() if char_uuid else ""
    # Si es paquete de cámara Laxasfit/HryFine, guardar prefijo genérico DF0006
    clean_hex = "DF0006" if hex_pattern.upper().startswith("DF0006") else hex_pattern
    config["notify_char_uuid"] = clean_uuid
    config["trigger_hex"] = clean_hex
    with open(CONFIG_FILE, "w") as f:
        json.dump(config, f, indent=4)
    print(f"\n[✓] Configuración guardada en {CONFIG_FILE}:")
    print(f"    - Característica UUID: {clean_uuid}")
    print(f"    - Patrón HEX disparador: {clean_hex}")


last_received_packet = {"char_uuid": None, "hex": None}


def notification_handler(sender, data: bytearray):
    now = datetime.datetime.now().strftime("%H:%M:%S.%f")[:-3]
    hex_str = data.hex(" ").upper()
    hex_compact = data.hex().upper()
    sender_uuid = str(sender)

    last_received_packet["char_uuid"] = sender_uuid
    last_received_packet["hex"] = hex_compact

    # Representación ASCII amigable (caracteres imprimibles)
    ascii_repr = "".join(chr(b) if 32 <= b <= 126 else "." for b in data)

    print(f"[{now}] ➜ UUID: {sender_uuid}")
    print(f"          HEX:   {hex_str} (Longitud: {len(data)} bytes)")
    print(f"          ASCII: {ascii_repr}")
    print("-" * 75)


async def run_sniffer(address: str, target_char: str = None):
    print(f"\n[+] Localizando dispositivo {address}...")
    print("[*] Asegúrate de que:")
    print("    1. El reloj NO esté conectado al celular (desactiva el Bluetooth de tu teléfono).")
    print("    2. La pantalla del reloj esté encendida.")
    print("    3. El reloj esté cerca de la PC.")

    target = address

    while True:
        try:
            print(f"\n[+] Conectando a {address} (pantalla encendida)...")
            async with BleakClient(address, timeout=12.0) as client:
                if not client.is_connected:
                    print("[!] No se pudo conectar. Reintentando...")
                    await asyncio.sleep(2)
                    continue

                print(f"[✓] Conectado exitosamente con {address}")
                print("\n" + "=" * 80)
                print("ESTRUCTURA DE SERVICIOS Y CARACTERÍSTICAS GATT")
                print("=" * 80)

                notify_chars = []
                for service in client.services:
                    print(f"\n[Servicio] {service.uuid} ({service.description})")
                    for char in service.characteristics:
                        props = ",".join(char.properties)
                        is_sub = "notify" in char.properties or "indicate" in char.properties
                        marker = " [★ NOTIFY/INDICATE]" if is_sub else ""
                        print(f"   └── [Char] {char.uuid} | Props: [{props}]{marker}")
                        if is_sub:
                            notify_chars.append(char)

                print("\n" + "=" * 80)
                if not notify_chars:
                    print("[!] No se encontraron características de notificación.")
                    return

                chars_to_sub = []
                if target_char:
                    chars_to_sub = [c for c in notify_chars if target_char.lower() in c.uuid.lower()] or notify_chars
                else:
                    chars_to_sub = notify_chars

                print(f"[+] Suscribiendo a {len(chars_to_sub)} característica(s) de notificación:")
                for c in chars_to_sub:
                    print(f"    - {c.uuid} ({c.description})")
                    try:
                        await client.start_notify(c.uuid, notification_handler)
                    except Exception as e:
                        print(f"    [!] Error al suscribir a {c.uuid}: {e}")

                print("\n" + "#" * 80)
                print(" SNIFFER ACTIVO: ESCUCHANDO PAQUETES EN TIEMPO REAL")
                print(" Presiona la pantalla en Cámara/Música en el reloj.")
                print(" Presiona Ctrl+C cuando quieras guardar o terminar.")
                print("#" * 80 + "\n")

                while client.is_connected:
                    await asyncio.sleep(0.5)

                print(f"\n[!] El reloj {address} se ha desconectado (pantalla apagada o fuera de rango).")
                print("[*] Enciende la pantalla del reloj; reconectando automáticamente en 2 segundos...")
                await asyncio.sleep(2)

        except (asyncio.CancelledError, KeyboardInterrupt):
            print("\n[+] Finalizando sniffer...")
            break
        except Exception as e:
            print(f"[!] Error de enlace ({e}). Reintentando en 3s... (toca la pantalla del reloj)")
            await asyncio.sleep(3)

    if last_received_packet["hex"]:
        print("\n" + "=" * 60)
        print("ÚLTIMO PAQUETE CAPTURADO:")
        print(f"UUID: {last_received_packet['char_uuid']}")
        print(f"HEX:  {last_received_packet['hex']}")
        print("=" * 60)
        try:
            resp = input("¿Deseas guardar este paquete como disparador en config.json? (s/n): ").strip().lower()
            if resp == "s":
                save_trigger_config(last_received_packet["char_uuid"], last_received_packet["hex"])
        except (KeyboardInterrupt, EOFError):
            pass


def main():
    parser = argparse.ArgumentParser(description="Sniffer BLE para Smartwatch")
    parser.add_argument("-a", "--address", type=str, help="Dirección MAC del Smartwatch (o lee de config.json)")
    parser.add_argument("-c", "--char", type=str, help="UUID específico de la característica a escuchar")
    args = parser.parse_args()

    address = args.address
    if not address:
        cfg = load_config()
        address = cfg.get("device_address")

    if not address:
        print("[!] No se proporcionó dirección MAC.")
        print("    Ejecuta primero: python3 scanner.py -s")
        print("    O especifícala con: python3 sniffer.py -a <DIRECCION_MAC>")
        sys.exit(1)

    try:
        asyncio.run(run_sniffer(address, target_char=args.char))
    except KeyboardInterrupt:
        print("\n[+] Sniffer terminado por el usuario.")


if __name__ == "__main__":
    main()
