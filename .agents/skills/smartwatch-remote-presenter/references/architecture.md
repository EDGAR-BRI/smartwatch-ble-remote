# Arquitectura y Protocolos: Smartwatch Remote Presenter

## 1. Topología de Conexión

```
   ┌──────────────────────┐
   │  Smartwatch / Band   │
   └──────────┬───────────┘
              │  Bluetooth (BLE GATT o Classic AVRCP)
              ▼
   ┌──────────────────────┐
   │   Android App        │  (Flutter + Kotlin)
   │  - MediaSession      │  (Control de volumen y música)
   │  - BLE Scanner       │  (Captura paquetes shutter)
   │  - AudioTrack Loop   │  (Simulador de reproducción silenciosa)
   │  - OTA Downloader    │  (Descarga e instalación de APK)
   └──────────┬───────────┘
              │  Wi-Fi (WebSocket seguro WSS puerto 8888 o WS puerto 8080)
              ▼
   ┌──────────────────────┐
   │  Linux PC Bridge     │  (Python aiohttp + asyncio)
   │  - VirtualClicker    │  (evdev uinput -> /dev/uinput)
   │  - Web UI / OTA API  │  (Static HTML + /api/app-info)
   └──────────┬───────────┘
              │  Kernel Event Subsystem
              ▼
   ┌──────────────────────┐
   │  X11 / Wayland Apps  │  (Canva, Google Slides, Evince, LibreOffice)
   └──────────────────────┘
```

---

## 2. Protocolos y Mensajería

### Mensajes WebSocket (Móvil ➔ PC)

- **Avanzar Diapositiva (Forward):**
  ```json
  {
    "event": "forward",
    "timestamp": 1791941000000
  }
  ```
- **Retroceder Diapositiva (Back):**
  ```json
  {
    "event": "back",
    "timestamp": 1791941000000
  }
  ```
- **Disparo de Obturador BLE (Shutter con secuencia):**
  ```json
  {
    "event": "shutter",
    "sequence": 14,
    "timestamp": 1791941000000
  }
  ```

### Mensajes WebSocket (PC ➔ Móvil - Feedback)
El servidor confirma las acciones para activar el destello visual en pantalla:
```json
{
  "action": "forward"
}
```

---

## 3. Endpoints HTTP / HTTPS del Servidor

| Ruta | Método | Descripción |
| :--- | :--- | :--- |
| `/` | `GET` | Interfaz web con botones de prueba e instalador web |
| `/ws` | `GET` | Endpoint WebSocket bidireccional |
| `/api/app-info` | `GET` | Metadatos dinámicos del APK (versión, tamaño, fecha de compilación) |
| `/version` | `GET` | Alias de `/api/app-info` |
| `/app.apk` | `GET` | Descarga directa del APK de producción con cabeceras `no-cache` |
| `/download` | `GET` | Alias de `/app.apk` |
