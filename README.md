# ⌚ Smartwatch BLE Remote Presenter

Control remoto de presentaciones (Canva, Google Slides, LibreOffice, PDF) utilizando un reloj inteligente genérico (**Laxasfit / HryFine / Chipset JieLi AC69xx/AC70xx**) mediante **Bluetooth Low Energy (BLE)** en **Linux (Wayland y X11)**.

---

## 🎯 Características

- **Simulación Nativa de Teclas en Linux:** Utiliza el subsistema del kernel `evdev` y `/dev/uinput` para emular teclas de hardware (`KEY_RIGHT` y `KEY_LEFT`), compatible de forma transparente con Wayland, X11 y cualquier navegador web.
- **Doble Control de Diapositivas:**
  - **1 Toque en el reloj:** Avanzar diapositiva (`RIGHT` ➔).
  - **Doble Toque rápido (<500 ms):** Retroceder diapositiva (`LEFT` ⬅️).
- **Desduplicación por Número de Secuencia:** Filtra a nivel de protocolo los paquetes en ráfaga (*burst*) que emite el reloj en una sola pulsación física.
- **Dos Modos de Operación:**
  1. **Modo Directo en PC (`remote_clicker.py`):** Conexión BLE directa entre el reloj y la PC con BlueZ.
  2. **Modo Puente Web Bluetooth (`web_bridge.py`):** Servidor local con interfaz web para teléfonos Android (Google Chrome) que actúa como puente BLE ➔ Wi-Fi ➔ PC, garantizando cero desconexiones y alcance inalámbrico extendido.
- **Arquitectura de App Nativa Documentada:** Guía completa para compilar una app en Flutter en [`OPCION2_FLUTTER_ANDROID.md`](OPCION2_FLUTTER_ANDROID.md).

---

## 🔬 Ingeniería Inversa del Protocolo (Laxasfit / HryFine)

Durante las pruebas se aisló la firma del servicio y características GATT:

* **Servicio Nordic UART (NUS):** `6e400001-b5a3-f393-e0a9-e50e24dcca9f`
* **Característica Notify (TX):** `6e400003-b5a3-f393-e0a9-e50e24dcca9f`
* **Estructura del paquete de disparo (Cámara Remota):**
  ```text
  HEX: DF 00 06 [Chk] 0C 01 [Seq] 00 01 01
  ```
  - `DF 00 06`: Encabezado y longitud de payload (6 bytes).
  - `0C 01`: Código de comando (OpCode `0x0C` = Cámara, `0x01` = Disparador).
  - `[Seq]`: Byte de secuencia incremental (`0x02`, `0x03`, `0x04`...).
  - `00 01 01`: Acción del obturador.

---

## ⚡ Onboarding Rápido para Laptop (Recomendado)

Si estás instalando esto en tu laptop, preparamos un asistente automatizado que configura permisos de kernel `/dev/uinput`, entorno virtual, firewall y certificados SSL en 1 solo comando:

```bash
git clone https://github.com/EDGAR-BRI/smartwatch-ble-remote.git
cd smartwatch-ble-remote
./setup_laptop.sh
```

📖 **Consulta la [Guía Completa de Onboarding (ONBOARDING.md)](ONBOARDING.md)** para instrucciones paso a paso, alias para tu terminal y configuración de servicio en segundo plano.

### 📦 Atajos Rápidos con NPM (`package.json`)

| Comando | Acción |
| :--- | :--- |
| `npm start` | Inicia el servidor puente de diapositivas (`web_bridge.py`) |
| `npm run status` | Verifica el estado del servidor y del APK compilado |
| `npm run stop` | Detiene el servidor en segundo plano si quedó abierto |
| `npm run setup` | Ejecuta el script de onboarding/permisos en tu laptop |
| `npm run build:apk` | Compila un nuevo APK de release en Flutter |
| `npm run scanner` | Escanea y detecta la MAC de tu smartwatch BLE |

---

## 🚀 Instalación Manual y Requisitos

### Requisitos del sistema
- Linux (Ubuntu, Debian, Arch, Fedora, etc.)
- Python 3.10+
- BlueZ y permisos de escritura en `/dev/uinput` (ver sección de permisos abajo).

### Preparar el entorno virtual manualmente
```bash
# Crear entorno virtual e instalar dependencias
python3 -m venv venv
./venv/bin/pip install -r requirements.txt
```

---

## 🛠️ Uso

### Fase 1: Escanear dispositivos BLE
Para identificar la dirección MAC de tu reloj inteligente:
```bash
./venv/bin/python scanner.py -s
```
*(Guarda la MAC seleccionada automáticamente en `config.json`).*

---

### Fase 2: Sniffer de paquetes en tiempo real
Para inspeccionar el árbol GATT y comprobar los bytes que emite el reloj:
```bash
./venv/bin/python sniffer.py
```

---

### Fase 3: Daemon de Diapositivas (Modo Directo)
Ejecuta el control remoto en segundo plano para tus presentaciones:
```bash
./venv/bin/python remote_clicker.py
```
* **Opciones CLI:**
  - `-k PAGEDOWN`: Cambiar la tecla de avance (def: `RIGHT`).
  - `-kb PAGEUP`: Cambiar la tecla de retroceso (def: `LEFT`).
  - `--no-double-tap`: Desactivar el doble toque y usar solo avance simple.
  - `-d 300`: Cambiar el tiempo de anti-rebote en milisegundos.

---

### Modo Puente Web Bluetooth (Recomendado para Máxima Estabilidad)
Si el reloj tiende a suspenderse cuando se conecta a la PC de escritorio, usa tu teléfono como puente:

1. Ejecuta el servidor en la PC:
   ```bash
   ./venv/bin/python web_bridge.py
   ```
2. En tu celular (Google Chrome), abre:
   - **Vía Wi-Fi:** `https://<TU_IP_LOCAL>:8443`
   - **Vía USB (ADB):** Corre `adb reverse tcp:8080 tcp:8080` y abre `http://localhost:8080`.
3. Pulsa **"🔗 Conectar Smartwatch"** en el navegador del celular.
4. Abre la **Cámara** en tu reloj y pásalo todo desde tu muñeca.

---

## 🔑 Permisos en Linux (`/dev/uinput`)

Para que el usuario pueda crear teclados virtuales sin usar `sudo`:
```bash
sudo setfacl -m u:$USER:rw /dev/uinput
```
O añade una regla udev en `/etc/udev/rules.d/99-uinput.rules`:
```udev
KERNEL=="uinput", MODE="0660", GROUP="input", TAG+="uaccess"
```

---

## 📄 Licencia
Distribuido bajo la licencia MIT.
