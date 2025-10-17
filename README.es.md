
Simetrio — ayudante unificado de build y pruebas
===============================================

Resumen
-------
Simetrio es un envoltorio ligero sobre las herramientas de build, VM y UI web ya presentes en el repositorio. Proporciona:

- Una CLI compacta (`scripts/simetrio`) que orquesta build, servir noVNC, limpieza y comprobaciones preflight.
- Una TUI opcional a pantalla completa y coloreada (`scripts/simetrio_tui.py`) implementada con Textual para uso interactivo.
- Pequeños scripts helper (bash) que realizan el trabajo pesado (construcción de rootfs Debian con debootstrap, creación de una imagen booteable en una VM Multipass en macOS, servir una VM QEMU por navegador con noVNC).

Objetivos y principios de diseño
-------------------------------
- Valores por defecto no destructivos: nada se borra ni sobrescribe salvo que el usuario confirme explícitamente (p. ej. `--yes`).
- Mantener comportamiento existente: la mayor parte de la lógica se delega a los scripts bash para evitar duplicar pasos complejos y probados.
- Portabilidad del host: en macOS los scripts prefieren ejecutar debootstrap y creación de imagen dentro de una instancia Multipass para evitar restricciones de montaje (nodev/noexec). En Linux se puede ejecutar localmente y usar QEMU/KVM cuando esté disponible.
- UX-first: proporcionar una TUI accesible para flujos interactivos sin renunciar a la CLI para scripting y CI.

Contenido de esta carpeta
-------------------------
- `simetrio` — punto de entrada CLI en Python (ejecutable).
- `simetrio_tui.py` — TUI opcional (requiere textual + rich).
- `requirements-simetrio.txt` — dependencias mínimas para la TUI.

Flujos y scripts clave
----------------------

- `multipass-run.sh`
	- Propósito: construir un rootfs Debian con `debootstrap` dentro de una VM Multipass (flujo pensado para macOS) y producir una imagen .img booteable con tabla de particiones y GRUB.
	- Uso: cuando quieras una imagen Debian booteable para probar en QEMU o grabar en soporte.
	- Flags importantes: `--name`, `--mem`, `--cpus`, `--disk`, `--with-kde`, `--with-calamares`.

- `build-rootfs-debian.sh`
	- Propósito: debootstrappear un root filesystem Debian (por defecto bookworm) con paquetes opcionales instalados en el chroot.

- `novnc-run.sh`
	- Prepara un pequeño runtime noVNC (venv + websockify) y arranca QEMU para exponer la .img generada vía VNC/proxy web.

- `clean-build.sh` y `stop-novnc.sh`
	- Ayudantes para eliminar artefactos y detener procesos. `clean-build.sh` puede eliminar la instancia Multipass si se solicita explícitamente.

Cómo usar la CLI
----------------

Desde la raíz del repositorio:

```bash
./scripts/simetrio check
```

Para construir una imagen booteable (flujo multipass en macOS):

```bash
./scripts/simetrio build --name stralyx --mem 4G --cpus 2 --disk 20G --with-kde --with-calamares
```

Para servir una imagen con noVNC:

```bash
./scripts/simetrio novnc build/Stralyx/output/debian-smoke.img
```

Para detener runs iniciados por los scripts:

```bash
./scripts/simetrio stop
```

Para limpiar artefactos y eliminar la instancia (opt-in):

```bash
./scripts/simetrio clean --yes --remove-instance --instance-name stralyx
```

TUI interactiva
---------------

Instalar dependencias:

```bash
python3 -m pip install -r scripts/requirements-simetrio.txt
```

Arrancar la TUI:

```bash
./scripts/simetrio
```

Instalar Multipass
-------------------
Para usar el flujo de `multipass-run.sh` necesitas tener Multipass instalado en tu host. A continuación hay instrucciones concisas (español) para macOS, Windows y Linux, y pasos rápidos de verificación.

macOS
- Homebrew (recomendado):

```bash
# Instalar (si no tienes Homebrew):
# /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install --cask multipass
```

- Instalador directo: descarga el paquete .dmg desde https://multipass.run y sigue el instalador.

Notas macOS: Multipass aprovecha la virtualización integrada (Hypervisor.framework) en Intel y Apple Silicon; no necesita VirtualBox. En Apple Silicon asegúrate de usar la versión ARM/compatible que proporciona el instalador/Homebrew.

Windows
- Instalador MSI: descarga el instalador desde https://multipass.run y ejecútalo como administrador.
- winget (Windows 10/11):

```powershell
winget install --id Canonical.Multipass -e
```

- Chocolatey:

```powershell
choco install multipass
```

Notas Windows: Multipass en Windows suele usar Hyper-V o la integración WSL2. En Windows Home puede requerir habilitar la característica de plataforma de máquina virtual/WSL2. Ejecuta el instalador con privilegios de administrador.

Linux
- Snap (recomendado en muchas distribuciones):

```bash
sudo snap install multipass --classic
```

- Debian/Ubuntu (repositorios):

```bash
sudo apt update
sudo apt install -y multipass
```

Si tu distribución no dispone de snap o del paquete, consulta la página oficial de Multipass para instrucciones específicas de la distro.

Verificación rápida
- Comprobar versión:

```bash
multipass version
```

- Listar instancias disponibles:

```bash
multipass ls
```

- Lanzar una VM de prueba, ejecutar un comando y eliminarla:

```bash
multipass launch --name simetrio-test --mem 1G --cpus 1 --disk 2G
multipass exec simetrio-test -- uname -a
multipass delete simetrio-test
multipass purge
```

Notas de virtualización y permisos
- Asegúrate de que la virtualización esté habilitada en la BIOS/UEFI en máquinas físicas.
- En macOS y Windows no suele ser necesario ejecutar Multipass como root después de la instalación, pero el instalador/activación puede requerir permisos elevados.
- Si encuentras errores relacionados con permisos o con backends hipervisores, revisa los logs de Multipass (`multipass --help` y `multipass logs <instance>`).
