# Solución de Problemas: Smartwatch Remote Presenter

## 1. Error de Puerto en Uso (`[Errno 98] address already in use`)

### Síntoma:
Al ejecutar `./venv/bin/python web_bridge.py`, aparece:
`OSError: [Errno 98] error while attempting to bind on address ('0.0.0.0', 8080): [errno 98] address already in use`

### Solución:
El servidor ya se encuentra corriendo en segundo plano o una instancia previa quedó colgada.
1. Localizar el proceso:
   ```bash
   lsof -i :8080 -i :8888
   ```
2. Finalizar el proceso antiguo:
   ```bash
   kill -9 <PID>
   ```

---

## 2. Permiso Denegado en `/dev/uinput` en Linux

### Síntoma:
Error en Python: `PermissionError: [Errno 13] Permission denied: '/dev/uinput'`

### Solución:
1. Asegurarse de que el usuario pertenece al grupo `input`:
   ```bash
   sudo usermod -aG input $USER
   ```
2. Crear o verificar la regla udev en `/etc/udev/rules.d/99-uinput.rules`:
   ```text
   KERNEL=="uinput", MODE="0660", GROUP="input"
   ```
3. Recargar reglas:
   ```bash
   sudo udevadm control --reload-rules && sudo udevadm trigger
   ```

---

## 3. La app móvil se cierra o deja de responder al bloquear la pantalla

### Síntoma:
Cuando el teléfono se bloquea o pasa más de 1 minuto con la pantalla apagada, los giros de la corona o clics del reloj ya no avanzan diapositivas.

### Solución:
Android aplica "Doze mode" y "App Standby" agresivo:
1. En la aplicación móvil, pulsar sobre el banner de color ámbar: **"Habilitar segundo plano sin cortes"** y aceptar la excepción de optimización de batería.
2. Comprobar que la notificación persistente **"Smartwatch Presenter Activo"** esté visible en la barra de notificaciones del teléfono.
3. Asegurarse de que el switch **"Música y Rueda del Reloj"** esté activado (verde).

---

## 4. El reloj no muestra los controles de música

### Síntoma:
Al ir a la pantalla de música en el smartwatch, dice "Desconectado" o no reacciona al pulsar Siguiente/Anterior.

### Solución:
1. El reloj debe estar conectado al teléfono mediante **Bluetooth Clásico** (no solo por BLE). Verificar en los Ajustes de Bluetooth del teléfono que el reloj figure como dispositivo conectado para audio/llamadas.
2. En la app móvil, apagar y volver a encender el switch **"Música y Rueda del Reloj"** para que el hilo de `AudioTrack` silencioso solicite nuevamente foco de audio al sistema.

---

## 5. El APK descargado por OTA no se instala o marca error de análisis

### Síntoma:
Al tocar "Actualizar Ahora" en la app móvil, tras la descarga aparece "Error al analizar el paquete" o no se abre el asistente.

### Solución:
1. Comprobar que en Android esté activado el permiso **"Instalar aplicaciones desconocidas"** para la app Smartwatch Presenter (`Settings > Apps > Smartwatch Presenter > Install unknown apps`).
2. Verificar que el APK en la PC no esté a medio compilar. Revisar con:
   ```bash
   curl -k -s https://127.0.0.1:8888/api/app-info
   ```
   El campo `size_mb` debe rondar los ~48-50 MB y `apk_exists` debe ser `true`.
