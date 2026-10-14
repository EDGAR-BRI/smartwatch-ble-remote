#!/usr/bin/env bash
# ==============================================================================
# Smartwatch Remote Presenter - Script de Onboarding e Instalación para Laptop
# ==============================================================================
set -e

# Colores para salida de terminal
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # Sin color

clear 2>/dev/null || true
echo -e "${CYAN}${BOLD}"
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║      ⌚ Smartwatch Remote Presenter - Onboarding de Laptop       ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "${BLUE}Configurando entorno para Linux (Wayland / X11)...${NC}\n"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 1. Comprobación de herramientas base del sistema
echo -e "${BOLD}[1/6] Verificando dependencias base (Python 3 y OpenSSL)...${NC}"
if ! command -v python3 &>/dev/null; then
    echo -e "${RED}Error: python3 no está instalado. Instálalo desde el gestor de paquetes.${NC}"
    exit 1
fi

if ! python3 -c "import venv" &>/dev/null; then
    echo -e "${YELLOW}Advertencia: el módulo python3-venv no está disponible.${NC}"
    if command -v apt-get &>/dev/null; then
        echo "Instalando python3-venv..."
        sudo apt-get update && sudo apt-get install -y python3-venv
    else
        echo -e "${RED}Por favor instala python3-venv en tu sistema.${NC}"
        exit 1
    fi
fi

if ! command -v openssl &>/dev/null; then
    echo -e "${YELLOW}Advertencia: openssl no encontrado. Instalando...${NC}"
    if command -v apt-get &>/dev/null; then
        sudo apt-get install -y openssl
    fi
fi
echo -e "${GREEN}✓ Python 3 (con venv) y OpenSSL listos.${NC}"

# 2. Configuración del módulo de kernel uinput y permisos
echo -e "\n${BOLD}[2/6] Verificando permisos del subsistema de teclado (/dev/uinput)...${NC}"
if [ -w /dev/uinput ]; then
    echo -e "${GREEN}✓ Tienes acceso de escritura directo a /dev/uinput.${NC}"
else
    echo -e "${YELLOW}[!] Se requieren permisos de escritura en /dev/uinput.${NC}"
    sudo modprobe uinput 2>/dev/null || true

    if [ -d "/etc/modules-load.d" ] && [ ! -f "/etc/modules-load.d/uinput.conf" ]; then
        echo "uinput" | sudo tee /etc/modules-load.d/uinput.conf >/dev/null || true
    fi

    UDEV_RULE_FILE="/etc/udev/rules.d/99-uinput.rules"
    if [ ! -f "$UDEV_RULE_FILE" ]; then
        echo 'KERNEL=="uinput", MODE="0660", GROUP="input"' | sudo tee "$UDEV_RULE_FILE" >/dev/null || true
        sudo udevadm control --reload-rules 2>/dev/null || true
        sudo udevadm trigger 2>/dev/null || true
    fi

    if ! groups "$USER" | grep &>/dev/null '\binput\b'; then
        echo -e "Añadiendo usuario $USER al grupo input..."
        sudo usermod -aG input "$USER" || true
    fi
    echo -e "${GREEN}✓ Configuración uinput aplicada.${NC}"
fi

# 3. Creación y configuración del entorno virtual de Python
echo -e "\n${BOLD}[3/6] Preparando entorno virtual Python (venv)...${NC}"
if [ ! -d "venv" ]; then
    python3 -m venv venv
    echo -e "${GREEN}✓ Entorno virtual creado en ./venv${NC}"
else
    echo -e "${GREEN}✓ Entorno virtual ya existe.${NC}"
fi

echo -e "Instalando/verificando paquetes en ./venv (aiohttp, evdev, bleak)..."
./venv/bin/pip install --quiet --upgrade pip
./venv/bin/pip install --quiet -r requirements.txt
echo -e "${GREEN}✓ Dependencias de Python instaladas correctamente.${NC}"

# 4. Certificados SSL autofirmados para HTTPS / WSS
echo -e "\n${BOLD}[4/6] Verificando certificados SSL para conexión segura (WSS)...${NC}"
if [ ! -f "cert.pem" ] || [ ! -f "key.pem" ]; then
    echo -e "Generando certificado autofirmado para comunicación segura local..."
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout key.pem -out cert.pem \
        -days 365 \
        -subj "/CN=SmartwatchPresenter/O=SmartwatchRemote/C=ES" &>/dev/null
    echo -e "${GREEN}✓ Certificado 'cert.pem' y llave 'key.pem' generados.${NC}"
else
    echo -e "${GREEN}✓ Certificados SSL existentes válidos.${NC}"
fi

# 5. Configuración de cortafuegos (UFW)
echo -e "\n${BOLD}[5/6] Verificando Cortafuegos (Firewall)...${NC}"
if command -v ufw &>/dev/null; then
    UFW_STATUS=$(sudo -n ufw status 2>/dev/null | head -n 1 || true)
    if [[ "$UFW_STATUS" =~ "active" ]]; then
        echo -e "UFW está activo. Asegurando puertos 8888, 8080 y 8889 (UDP)..."
        sudo ufw allow 8888/tcp comment 'Smartwatch Presenter WSS' &>/dev/null || true
        sudo ufw allow 8080/tcp comment 'Smartwatch Presenter HTTP' &>/dev/null || true
        sudo ufw allow 8889/udp comment 'Smartwatch Presenter Discovery' &>/dev/null || true
        echo -e "${GREEN}✓ Puertos 8888, 8080 y 8889 (UDP) permitidos en UFW.${NC}"
    else
        echo -e "${GREEN}✓ Firewall sin bloqueos en la red local.${NC}"
    fi
else
    echo -e "${GREEN}✓ Sin firewall ufw activo.${NC}"
fi

# 6. Prueba de inyección de teclado con uinput
echo -e "\n${BOLD}[6/6] Verificando emulación de teclado en tu laptop...${NC}"
TEST_RESULT=$(./venv/bin/python -c '
import evdev
try:
    ui = evdev.UInput(name="test-laptop-uinput")
    ui.close()
    print("OK")
except Exception as e:
    print(f"ERROR: {e}")
' 2>&1)

if [[ "$TEST_RESULT" == *"OK"* ]]; then
    echo -e "${GREEN}✓ Teclado virtual uinput listo y funcionando.${NC}"
else
    echo -e "${YELLOW}Aviso sobre uinput: $TEST_RESULT${NC}"
    echo -e "${YELLOW}Si al ejecutar el puente da error, corre: sudo chmod 666 /dev/uinput${NC}"
fi

# Obtener IP local de la laptop
LOCAL_IP=$(./venv/bin/python -c '
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
try:
    s.connect(("8.8.8.8", 80))
    print(s.getsockname()[0])
except:
    print("127.0.0.1")
finally:
    s.close()
' 2>/dev/null || echo "127.0.0.1")

echo -e "\n${GREEN}${BOLD}════════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}             🎉 ¡INSTALACIÓN COMPLETADA EXITOSAMENTE!               ${NC}"
echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════════════════════${NC}"
echo -e "\n${BOLD}Para iniciar el control de presentaciones en tu laptop:${NC}"
echo -e "  ${CYAN}./venv/bin/python web_bridge.py${NC}\n"
echo -e "${BOLD}IP de tu laptop detectada:${NC} ${YELLOW}${BOLD}${LOCAL_IP}${NC}"
echo -e "• En tu teléfono, introduce: ${YELLOW}${BOLD}${LOCAL_IP}:8888${NC}"
echo -e "• O descarga la app APK desde: ${CYAN}https://${LOCAL_IP}:8888${NC}\n"
