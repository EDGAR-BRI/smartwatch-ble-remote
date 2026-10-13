#!/usr/bin/env python3
"""
Fase 1: Escaneo y descubrimiento de dispositivos BLE (Smartwatch)
"""
import asyncio
import argparse
import json
import os
import sys
from bleak import BleakScanner

CONFIG_FILE = "config.json"


def format_manufacturer_data(mfg_data: dict) -> str:
    if not mfg_data:
        return "N/A"
    parts = []
    for company_id, data in mfg_data.items():
        parts.append(f"0x{company_id:04X}:{data.hex()}")
    return ", ".join(parts)


async def scan_ble_devices(timeout: float = 8.0, filter_name: str = None):
    print(f"\n[+] Iniciando escaneo BLE por {timeout} segundos...")
    print("[*] Asegúrate de que el reloj tenga la pantalla encendida o esté en rango.\n")

    devices_dict = {}

    def detection_callback(device, advertisement_data):
        devices_dict[device.address] = (device, advertisement_data)

    scanner = BleakScanner(detection_callback=detection_callback)
    await scanner.start()
    await asyncio.sleep(timeout)
    await scanner.stop()

    discovered = list(devices_dict.values())
    if not discovered:
        print("[!] No se detectó ningún dispositivo BLE.")
        return []

    # Filtrar si se solicitó
    if filter_name:
        discovered = [
            (d, adv) for (d, adv) in discovered
            if (adv.local_name and filter_name.lower() in adv.local_name.lower()) or
               (d.name and filter_name.lower() in d.name.lower())
        ]

    # Ordenar por RSSI descendente (más cercano primero)
    discovered.sort(key=lambda item: item[1].rssi, reverse=True)

    print("=" * 85)
    print(f"{'#':<3} | {'NOMBRE':<25} | {'DIRECCIÓN MAC':<20} | {'RSSI':<7} | {'SERVICIOS ADV'}")
    print("=" * 85)

    results = []
    for idx, (dev, adv) in enumerate(discovered, 1):
        name = adv.local_name or dev.name or "<Desconocido>"
        uuids = ", ".join(adv.service_uuids) if adv.service_uuids else "N/A"
        if len(uuids) > 25:
            uuids = uuids[:22] + "..."
        print(f"{idx:<3} | {name:<25} | {dev.address:<20} | {adv.rssi:<7} | {uuids}")
        results.append({
            "index": idx,
            "name": name,
            "address": dev.address,
            "rssi": adv.rssi,
            "service_uuids": adv.service_uuids,
            "manufacturer_data": format_manufacturer_data(adv.manufacturer_data)
        })

    print("=" * 85)
    return results


def save_to_config(address: str, name: str):
    config = {}
    if os.path.exists(CONFIG_FILE):
        try:
            with open(CONFIG_FILE, "r") as f:
                config = json.load(f)
        except Exception:
            config = {}
    config["device_address"] = address
    config["device_name"] = name
    with open(CONFIG_FILE, "w") as f:
        json.dump(config, f, indent=4)
    print(f"\n[✓] Dispositivo guardado en {CONFIG_FILE}: {name} ({address})")


async def main():
    parser = argparse.ArgumentParser(description="Escáner BLE para Smartwatch (Laxasfit/HryFine/JieLi)")
    parser.add_argument("-t", "--timeout", type=float, default=8.0, help="Tiempo de escaneo en segundos (def: 8)")
    parser.add_argument("-f", "--filter", type=str, default=None, help="Filtrar por coincidencia de nombre")
    parser.add_argument("-s", "--select", action="store_true", help="Permitir seleccionar un reloj para guardar en config.json")
    args = parser.parse_args()

    results = await scan_ble_devices(timeout=args.timeout, filter_name=args.filter)

    if results and args.select:
        try:
            choice = input("\nIngresa el número (#) del reloj para guardarlo en config.json (o Enter para salir): ").strip()
            if choice:
                idx = int(choice)
                selected = next((r for r in results if r["index"] == idx), None)
                if selected:
                    save_to_config(selected["address"], selected["name"])
                else:
                    print("[!] Número inválido.")
        except (ValueError, KeyboardInterrupt):
            print("\nOperación cancelada.")


if __name__ == "__main__":
    asyncio.run(main())
