# 🚀 Onboarding: Smartwatch Remote Presenter en tu Laptop

Esta guía te permite dejar la laptop lista para controlar diapositivas en **menos de 2 minutos** tras clonar el repositorio en cualquier distribución Linux (Ubuntu, Debian, Fedora, Arch, Manjaro, Linux Mint, etc.).

---

## ⚡ Inicio Rápido (3 Pasos)

Si acabas de clonar el repositorio en tu laptop, solo corre:

```bash
# 1. Entra a la carpeta del proyecto
cd smartwatch-ble-remote   # o smartwatch_remote

# 2. Ejecuta el asistente de onboarding automatizado
./setup_laptop.sh

# 3. Inicia el servidor puente de diapositivas
./venv/bin/python web_bridge.py
```

---

## 🛠️ ¿Qué configura `./setup_laptop.sh` automáticamente?

El script de onboarding se encarga de todo lo que suele requerir configuración manual en Linux:

1. **Permisos de Teclado Virtual (`/dev/uinput`):**
   - Carga el módulo de kernel `uinput`.
   - Crea la regla udev en `/etc/udev/rules.d/99-uinput.rules` para que nunca te pida `sudo`.
   - Añade tu usuario al grupo `input`.
   - Configura `/etc/modules-load.d/uinput.conf` para que el módulo persista tras reiniciar la laptop.
2. **Entorno Virtual de Python:**
   - Crea `./venv` e instala dependencias (`aiohttp`, `evdev`, `bleak`).
3. **Certificados de Seguridad SSL Autofirmados:**
   - Genera `cert.pem` y `key.pem` para cifrado WSS/HTTPS sin depender de internet externo.
4. **Cortafuegos (UFW):**
   - Abre los puertos `8888` (WSS seguro) y `8080` (HTTP local) si el firewall está activo.
5. **Diagnóstico Automático:**
   - Hace una prueba de inyección en `uinput` y muestra la **IP local** exacta de tu laptop.

---

## 📱 Conectar el Teléfono a la Laptop

### Caso A: Ya tienes la App Android instalada
1. Conecta tu laptop y tu teléfono a la **misma red Wi-Fi** (o comparte datos móviles desde tu teléfono a la laptop).
2. En la barra superior de la app en tu teléfono, introduce la IP de la laptop que apareció al iniciar el servidor (ej: `192.168.1.15:8888` o `10.0.0.3:8888`).
3. Toca el botón 🔄 de reconectar. El indicador "PC (Wi-Fi)" cambiará a **Conectado (Verde)**.

### Caso B: Es un teléfono nuevo o quieres descargar el APK
1. Con la laptop corriendo `./venv/bin/python web_bridge.py`, abre el navegador Chrome en tu teléfono y entra a:
   ```text
   https://<IP_DE_TU_LAPTOP>:8888
   ```
2. Acepta el certificado autofirmado ("Avanzado > Continuar a este sitio").
3. Toca el botón **📥 Descargar SmartwatchPresenter-v1.0.5.apk** e instálalo.

---

## 💡 Atajos y Automatización Recomendada

### 1. Alias rápido para tu terminal (`.bashrc` o `.zshrc`)
Para no escribir la ruta completa cada vez que des una presentación, agrega este alias:

```bash
echo 'alias presenter="cd '"$PWD"' && ./venv/bin/python web_bridge.py"' >> ~/.bashrc
source ~/.bashrc
```

Ahora simplemente abres una terminal y escribes:
```bash
presenter
```

---

### 2. (Opcional) Iniciar automáticamente como Servicio de Usuario (Systemd)
Si prefieres que el puente de control siempre esté encendido en segundo plano sin abrir una terminal:

Crea el archivo de servicio del usuario:
```bash
mkdir -p ~/.config/systemd/user
cat <<EOF > ~/.config/systemd/user/smartwatch-presenter.service
[Unit]
Description=Smartwatch Remote Presenter Bridge
After=network.target

[Service]
Type=simple
WorkingDirectory=$(pwd)
ExecStart=$(pwd)/venv/bin/python $(pwd)/web_bridge.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
```

Habilita y arranca el servicio:
```bash
systemctl --user daemon-reload
systemctl --user enable --now smartwatch-presenter.service
```

Para ver el estado o logs:
```bash
systemctl --user status smartwatch-presenter
journalctl --user -u smartwatch-presenter -f
```

---

## 📋 Checklist Antes de una Exposición o Presentación

Antes de subir al escenario o iniciar tu clase/reunión:

1. [ ] **Red:** Laptop y teléfono conectados a la misma red Wi-Fi (o Hotspot del celular).
2. [ ] **Servidor:** Correr `presenter` en la laptop y verificar que diga `[✓] Teclado virtual uinput listo`.
3. [ ] **App Móvil:** Abrir la app. Verificar:
   - Punto verde en **Reloj (BLE)**.
   - Punto verde en **PC (Wi-Fi)**.
   - Switch verde en **Música y Rueda del Reloj**.
4. [ ] **Prueba de Fuego:** Gira la corona/rueda o toca el botón de música en el reloj: la laptop debe avanzar y retroceder de diapositiva al instante.
5. [ ] **¡A presentar con las manos libres!** 🎯
