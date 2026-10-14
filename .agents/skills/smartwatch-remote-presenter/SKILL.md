---
name: smartwatch-remote-presenter
description: >-
  Guía completa y runbook para construir, configurar, depurar y mantener el sistema
  Smartwatch Remote Presenter (control de diapositivas Linux con reloj inteligente vía BLE,
  AVRCP multimedia, rueda/corona digital, puente WebSocket y uinput). Usar siempre que se
  trabaje en la integración de smartwatches/smartbands como controles remotos, simulación
  AVRCP en Android, teclado virtual uinput en Linux, o actualizaciones OTA de APK.
---

# Smartwatch Remote Presenter: Guía Técnica y Procedimientos

Este skill recopila la arquitectura, ingeniería inversa, protocolos y lecciones aprendidas para convertir cualquier reloj inteligente (smartband/smartwatch genérico o de marca) en un control remoto inalámbrico de diapositivas (Canva, PowerPoint, Presentaciones de Google, visores PDF) sobre Linux.

---

## 1. Arquitectura General del Sistema

El sistema resuelve las limitaciones de Bluetooth en Linux (fallas de emparejamiento BLE, falta de perfiles propietarios de cámara) utilizando el teléfono Android como puente de hardware inteligente:

```
[ Smartwatch / Smartband ]
   │
   ├── Modo 1: Obturador Cámara BLE (Nordic UART Service 6e400001)
   ├── Modo 2: Controles Música Bluetooth Clásico (AVRCP NEXT/PREV)
   └── Modo 3: Rueda / Corona Digital (VolumeProvider relativo)
   │
   ▼
[ Teléfono Android - Flutter + Kotlin Nativo ]
   │  - Captura eventos BLE / AVRCP / Volumen en segundo plano
   │  - AudioTrack silencioso continuo + Foreground Notification
   │  - Envía eventos JSON por WebSocket seguro (WSS)
   ▼
[ PC Linux - Python aiohttp Bridge (`web_bridge.py`) ]
   │  - Servidor HTTP/HTTPS + WSS (Puerto 8888 / 8080)
   │  - Detección dinámica de IP local y API `/api/app-info`
   ▼
[ Kernel Linux uinput (`evdev`) ]
   │  - Teclado virtual ('Smartwatch-Phone-Bridge')
   │  - Inyecta `KEY_RIGHT` (Avanzar), `KEY_LEFT` (Retroceder) o `KEY_U` (Pausa / Telón Canva)
   ▼
[ Diapositivas (Canva / Chrome / LibreOffice / Evince) ]
```

---

## 2. Modos de Entrada del Smartwatch

### Modo A: Obturador de Cámara BLE (GATT Propietario)
Muchos relojes chinos/genéricos (DaFit, FitPro, HryFine, etc.) usan el servicio **Nordic UART Service (NUS)**:
- **Service UUID:** `6e400001-b5a3-f393-e0a9-e50e24dcca9f`
- **Write Characteristic:** `6e400002-b5a3-f393-e0a9-e50e24dcca9f`
- **Notify Characteristic:** `6e400003-b5a3-f393-e0a9-e50e24dcca9f`
- **Batería GATT estándar:** Service `0x180F`, Char `0x2A19` (lectura porcentaje de 0 a 100).

**Lección Clave:** Al tocar el obturador en el reloj, este envía ráfagas de 3 a 5 paquetes idénticos con un contador de secuencia. Es **obligatorio** filtrar por número de secuencia (`seq == lastSeq`) o aplicar debounce (400ms) para evitar saltos múltiples de diapositivas.

### Modo B: Controles de Música Bluetooth Clásico (AVRCP)
Permite usar los botones físicos o de pantalla del reloj (Siguiente ⏭️, Anterior ⏮️, Play/Pausa ⏯️):
- **Siguiente (⏭️):** Inyecta `KEY_RIGHT` (Avanzar diapositiva).
- **Anterior (⏮️):** Inyecta `KEY_LEFT` (Retroceder diapositiva).
- **Play/Pausa (⏯️):** Inyecta `KEY_U` (Abre/cierra cortina o efecto telón en Canva).
- Se implementa en Android nativo mediante `android.media.session.MediaSession`.
- **Problema encontrado:** Si Android no está reproduciendo audio activamente, el reloj oculta los controles o el sistema desactiva el `MediaSession`.
- **Solución:**
  1. Solicitar foco de audio permanente: `audioManager.requestAudioFocus(AUDIOFOCUS_GAIN)`.
  2. Iniciar un hilo con un bucle continuo de `AudioTrack` reproduciendo PCM silencio (16-bit, 44.1kHz).
  3. Establecer `PlaybackState.STATE_PLAYING` con acciones completas de transporte.

### Modo C: Corona Digital / Rueda de Volumen
Permite avanzar o retroceder diapositivas girando la rueda física o corona del reloj inteligente:
- **Problema de Bluetooth Absolute Volume:** En Android moderno con Bluetooth Classic, el stack Bluetooth maneja el volumen absoluto modificando directamente `STREAM_MUSIC`, ignorando `VolumeProvider` de `MediaSession`. Además, `dispatchKeyEvent` filtraba `ACTION_UP`, provocando que el volumen del teléfono subiera y bajara en pantalla hasta saturarse (al 100% o 0%).
- **Solución Multicapa Robusta:**
  1. **Consumo de Eventos de Tecla:** En `dispatchKeyEvent`, interceptar y retornar `true` tanto para `ACTION_DOWN` como para `ACTION_UP` en `KEYCODE_VOLUME_UP` y `KEYCODE_VOLUME_DOWN`, anulando la ventana emergente de volumen en primer plano.
  2. **Receptor Dinámico + ContentObserver:** Registrar `BroadcastReceiver` para `android.media.VOLUME_CHANGED_ACTION` y `ContentObserver` sobre `Settings.System.CONTENT_URI` para capturar cualquier ajuste de volumen proveniente del Bluetooth AVRCP del reloj (pantalla encendida o apagada).
  3. **Bloqueo a Punto Neutro (Baseline Volume Lock):**
     - Al iniciar la sesión, se fija el volumen de medios en un punto medio neutral (`baselineVolume = maxVol / 2`, ej: 7).
     - Si el reloj gira en sentido horario: el volumen sube a 8 (`> 7`). Se dispara `forward` (avanzar) y se restablece instantáneamente a 7 con flag `0` (sin UI ni sonido).
     - Si el reloj gira en sentido antihorario: el volumen baja a 6 (`< 7`). Se dispara `back` (retroceder) y se restablece instantáneamente a 7.
     - De esta forma, el usuario puede girar la rueda infinitamente sin que el volumen del teléfono se sature al 100% ni se quede en 0%. Al salir, se restaura el volumen original del usuario.
- **Debounce:** Umbral de tiempo (140 ms) entre giros para evitar saltos dobles accidentales.

---

## 3. Ejecución Robusta en Segundo Plano (Pantalla Apagada)

Para evitar que Android cierre la aplicación cuando el usuario bloquea el teléfono o lo guarda en el bolsillo:
1. **Permisos en `AndroidManifest.xml`:**
   - `WAKE_LOCK`
   - `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`
   - `POST_NOTIFICATIONS`
   - `FOREGROUND_SERVICE`
   - `FOREGROUND_SERVICE_MEDIA_PLAYBACK`
   - `FOREGROUND_SERVICE_CONNECTED_DEVICE`
2. **Wakelock:** `WakelockPlus.enable()` en Flutter al iniciar.
3. **Exención de Batería:** Solicitar en runtime `Permission.ignoreBatteryOptimizations.request()`.
4. **Notificación Persistente:** `NotificationManager` con `setOngoing(true)` y canal de notificación dedicado.

---

## 4. Servidor Puente en Linux (`web_bridge.py`)

### Características Principales:
- **Detección Dinámica de IP:** `get_local_ip()` obtiene la IP local real (vía socket UDP a `8.8.8.8:80`) para que al cambiar de red Wi-Fi no requiera modificar código ni configuraciones manuales.
- **Doble Puerto:**
  - Puerto `8080` (HTTP): útil para pruebas locales o `adb reverse tcp:8080 tcp:8080`.
  - Puerto `8888` (HTTPS/WSS con certificado autofirmado): puerto abierto en UFW para conexión Wi-Fi sin restricciones.
- **Teclado Virtual con `evdev.uinput`:**
  - Requiere pertenecer al grupo `input` en Linux o regla udev:
    ```bash
    sudo usermod -aG input $USER
    ```
- **Lógica de Doble Toque:**
  - Si el usuario presiona el obturador 1 vez: espera 450 ms; si no hay otro toque, emite `KEY_RIGHT`.
  - Si pulsa 2 veces antes de 450 ms: cancela el avance y emite `KEY_LEFT`.
- **Auto-descubrimiento Local UDP (Zero Configuración):**
  - Puerto `8889` UDP broadcast.
  - La laptop responde a sondeos `"DISCOVER_SMARTWATCH_PRESENTER"` y además emite un beacon cada 3 segundos a `255.255.255.255:8889` con JSON (`ip`, `port`, `http_port`, `version`, `hostname`).
  - La app móvil (`RawDatagramSocket`) escucha en el puerto UDP y auto-rellena la IP y se conecta automáticamente sin que el usuario deba consultar la terminal.

---

## 5. Actualizador In-App (OTA) de APK, GitHub Releases y Limpieza de Caché

Permite actualizar la app móvil sin necesidad de ingresar al navegador web:
1. **Enlace Permanente en GitHub Releases:**
   - URL fija: `https://github.com/EDGAR-BRI/smartwatch-ble-remote/releases/latest/download/SmartwatchPresenter.apk`
   - Al publicar una nueva versión con tag `vX.X.X`, GitHub redirige automáticamente el endpoint `releases/latest/download` al binario más reciente, eliminando la necesidad de actualizar enlaces hardcodeados en el código.
2. **Servidor Puente (`web_bridge.py`):**
   - Expone `GET /api/app-info` y `GET /app.apk`.
   - **Fallback Inteligente:** Si la laptop no tiene Flutter instalado y no existe el APK compilado localmente, `GET /app.apk` emite una redirección HTTP 302 hacia el enlace permanente de GitHub Releases.
3. **Cliente Flutter:**
   - Comprueba versión al conectar por WebSocket y mediante botón de búsqueda en el AppBar.
   - Si hay actualización: descarga el archivo usando `HttpClient` directamente al `cacheDir` (con fallback automático a GitHub Releases si la PC local no lo tiene).
   - Diálogo de progreso en MB, porcentaje y origen del binario (Wi-Fi local o GitHub).
   - **Limpieza de Caché:** Al iniciar la app tras la actualización, si existe un archivo `update.apk` en caché (aprox. 50 MB), se elimina automáticamente para no malgastar espacio en disco.
4. **Instalación Segura en Android (FileProvider):**
   - Requiere `REQUEST_INSTALL_PACKAGES` en el Manifest.
   - `<paths>` en `res/xml/file_paths.xml` con `<cache-path name="cache" path="." />`.
   - Inicia `Intent.ACTION_VIEW` con `setDataAndType(apkUri, "application/vnd.android.package-archive")` y `FLAG_GRANT_READ_URI_PERMISSION`.

---

## 6. Feedback Háptico para el Bolsillo (Motor Nativo Vibrator)

Para que el orador tenga confirmación táctil con el teléfono en el bolsillo sin mirar la pantalla de proyección:
- **Motor de Hardware Nativo (`android.os.Vibrator`):**
  - Utiliza el servicio nativo de Android mediante MethodChannel (`vibrate`).
  - Garantiza funcionamiento con la **pantalla apagada y el móvil en el bolsillo**, independientemente de si la opción "vibrar al pulsar" del sistema está apagada.
  - Requiere el permiso `android.permission.VIBRATE` (permiso normal de sistema).
- **Patrones Diferenciados:**
  - **Avanzar Diapositiva (⏩):** 1 pulso de 100 ms.
  - **Retroceder Diapositiva (⏪):** 2 pulsos consecutivos (70 ms vibración, 90 ms pausa, 70 ms vibración).
  - **Play / Pausa (⏯️) / Tecla U:** 1 pulso pesado prolongado (240 ms).
- **Configurable:** Interruptor en la interfaz móvil para activar o silenciar las vibraciones con vibración de prueba inmediata al encenderlo.

---

## 7. Procedimientos de Operación y Comandos Frecuentes

### Iniciar el Puente en la PC
```bash
cd /home/edgar/dev/projets/smartwatch_remote
./venv/bin/python web_bridge.py
```

### Compilar Nueva Versión de la App Móvil
```bash
cd /home/edgar/dev/projets/smartwatch_remote/mobile_app
# 1. Incrementar versión en pubspec.yaml (ej: 1.0.7+8)
# 2. Compilar APK release
flutter build apk --release
```

### Verificar Estado y Endpoints desde Terminal
```bash
# Ver versión y estado del APK compilado
curl -k -s https://127.0.0.1:8888/api/app-info

# Comprobar descarga
curl -k -I https://127.0.0.1:8888/app.apk
```

---

## 8. Referencias y Documentación Detallada
- Para arquitectura y flujos de red: [architecture.md](./references/architecture.md)
- Para solución de problemas y errores comunes: [troubleshooting.md](./references/troubleshooting.md)
