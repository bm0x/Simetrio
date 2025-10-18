#!/usr/bin/env python3
"""
Simetrio TUI — full-screen, colored terminal UI using Textual.

Features:
- Large, colored, full-screen menu
- Forms to collect parameters for Build / Clean / noVNC
- Streams subprocess output into a log pane
- Delegates to existing bash scripts (multipass-run.sh, novnc-run.sh, clean-build.sh, stop-novnc.sh)

Install dependencies (one-time):
  python3 -m pip install -r scripts/requirements-simetrio.txt

Run:
  ./scripts/simetrio_tui.py

Notes:
- This UI intentionally delegates heavy work to the existing scripts to preserve behavior.
- If Textual isn't installed the script will show an instruction.
"""

import shutil
import subprocess
import sys
import threading
import platform
import tempfile
from pathlib import Path

try:
    from textual.app import App, ComposeResult  # type: ignore[import]
    from textual.widgets import Header, Footer, Button, Static, Input, Checkbox, TextLog  # type: ignore[import]
    from textual.containers import Horizontal, Vertical  # type: ignore[import]
    from textual.reactive import var  # type: ignore[import]
except Exception:
    print("Textual is not installed. Install dependencies with:")
    print("  python3 -m pip install -r scripts/requirements-simetrio.txt")
    sys.exit(1)

def find_repo_root():
    p = Path(__file__).resolve()
    cur = p.parent
    # walk upwards until we find README.md or reach filesystem root
    while cur != cur.parent:
        if (cur / 'README.md').exists():
            return cur
        cur = cur.parent
    return p.parent


REPO_ROOT = find_repo_root()
# Prefer 'bin' for executable scripts; fall back to 'scripts' for compatibility
if (REPO_ROOT / 'bin').exists():
    SCRIPTS_DIR = REPO_ROOT / 'bin'
else:
    SCRIPTS_DIR = REPO_ROOT / 'scripts'

# Helper to ensure scripts exist
def script_path(name):
    p = SCRIPTS_DIR / name
    # Prefer scripts/ but fall back to repo root for top-level executables
    if p.exists():
        return str(p)
    alt = REPO_ROOT / name
    if alt.exists():
        return str(alt)
    raise FileNotFoundError(f"Required script not found: {p} or {alt}")

class Menu(Static):
    pass

class SimetrioApp(App):
    CSS = """
    Screen {
        layout: horizontal;
        background: #0f1720;
    }
    .panel {
        border: heavy blue;
        padding: 1 2;
        background: #071018;
    }
    #right {
        width: 1fr;
    }
    #left {
        width: 40;
    }
    #title {
        background: darkblue;
        color: white;
        padding: 1;
        text-align: center;
        text-style: bold;
    }
    #log_title { text-style: bold; }
    """

    running = var(False)
    # require explicit double-confirm for elevated installs
    _elevate_pending = False
    # require explicit confirmation before running macOS PKG installer
    _pkg_install_pending = False

    def compose(self) -> ComposeResult:
        yield Header(show_clock=True)
        with Horizontal():
            with Vertical(id="left", classes="panel"):
                yield Static("Simetrio", id="title")
                yield Button("Build image", id="build")
                yield Button("Run noVNC", id="novnc")
                yield Button("Clean", id="clean")
                yield Button("Stop noVNC", id="stop")
                yield Button("Preflight check", id="check")
                yield Button("Deps check", id="deps")
                yield Button("Quit", id="quit")
            with Vertical(id="right", classes="panel"):
                yield Static("Parameters", id="params_title")
                # Basic inputs always visible
                yield Input(placeholder="Instance name (default: stralyx)", id="inst_name")
                yield Input(placeholder="Memory (e.g. 4G)", id="mem")
                yield Input(placeholder="CPUs (e.g. 2)", id="cpus")
                yield Input(placeholder="Disk (e.g. 20G)", id="disk")

                # Section toggles
                yield Button("▸ Opcionales", id="toggle_optional")
                with Vertical(id='section_optional'):
                    yield Checkbox(label="Install KDE", id="kde")
                    yield Checkbox(label="Install Calamares", id="calamares")

                yield Button("▸ Python / UI", id="toggle_python")
                with Vertical(id='section_python'):
                    yield Checkbox(label="Install Python reqs", id="install_python")
                    # UI deps could be added here in future

                yield Button("▸ Sistema", id="toggle_system")
                with Vertical(id='section_system'):
                    yield Checkbox(label="Install as admin (sudo)", id="elevate")
                    yield Checkbox(label="Install system deps", id="install_system")

                yield Button("Run Selected", id="run_selected")
                yield Button("Copy Log", id="copy_log")
            with Vertical(id="log", classes="panel"):
                yield Static("Output", id="log_title")
                self.textlog = TextLog(highlight=True, wrap=True, id="textlog")
                yield self.textlog
        yield Footer()

    def on_mount(self) -> None:
        """Initialize sections collapsed by default and set button labels."""
        # Map buttons to section titles
        mapping = {
            'toggle_optional': ('section_optional', 'Opcionales'),
            'toggle_python': ('section_python', 'Python / UI'),
            'toggle_system': ('section_system', 'Sistema')
        }
        for btn_id, (sec_id, title) in mapping.items():
            try:
                btn = self.query_one(f'#{btn_id}', Button)
                sec = self.query_one(f'#{sec_id}', Vertical)
            except Exception:
                continue
            # collapse sections initially
            try:
                sec.visible = False
            except Exception:
                # hide children if container doesn't support visible
                for c in list(sec.children):
                    try:
                        c.visible = False
                    except Exception:
                        pass
            try:
                btn.label = f'▸ {title}'
            except Exception:
                pass

    def on_button_pressed(self, event: Button.Pressed) -> None:
        btn_id = event.button.id
        if btn_id == 'quit':
            self.exit()
            return
        if btn_id in ('build','novnc','clean','stop','check','deps'):
            # mark which action to run; show selection in log
            self.action = btn_id
            self._append_log(f"Selected action: {btn_id}")
            if btn_id == 'novnc':
                # prompt for image path via input focus
                self.query_one('#inst_name').value = ''
                self.query_one('#inst_name').placeholder = 'Image path (e.g. build/Stralyx/output/debian-smoke.img)'
            elif btn_id == 'deps':
                # run dependency flow in background to stream output and detect missing packages
                t = threading.Thread(target=self.action_deps_flow, daemon=True)
                t.start()
            else:
                self.query_one('#inst_name').placeholder = 'Instance name (default: stralyx)'
        elif btn_id == 'relaunch':
            # Relaunch top-level simetrio CLI (detached)
            try:
                cmd = [sys.executable, script_path('simetrio')]
                self._append_log('Relaunching: ' + ' '.join(cmd))
                subprocess.Popen(cmd)
                self._append_log('Simetrio relaunched in background; exiting TUI.')
                self.exit()
            except Exception as e:
                self._append_log(f'Relaunch failed: {e}')
            return
        elif btn_id == 'copy_log':
            # copy the internal log buffer to clipboard (or file fallback)
            try:
                self._copy_log_to_clipboard()
            except Exception as e:
                self._append_log(f'Copy failed: {e}')
            return
        elif btn_id == 'run_selected':
            # gather params and execute
            try:
                action = getattr(self, 'action', None)
                if not action:
                    self._append_log('No action selected. Choose one of the menu buttons first.')
                    return
                params = self._gather_params()
                # require explicit confirmation when user requests elevated install
                if action == 'deps' and ((params.get('install_python') or params.get('install_system')) and params.get('elevate')):
                    if not self._elevate_pending:
                        self._elevate_pending = True
                        self._append_log('You have requested an elevated installation (sudo).')
                        self._append_log("To confirm, click 'Run Selected' again. This prevents accidental sudo usage.")
                        return
                    else:
                        # confirmed; reset flag and proceed
                        self._elevate_pending = False
                self._run_action(action, params)
            except Exception as e:
                self._append_log(f'Error preparing action: {e}')
        elif btn_id in ('toggle_optional','toggle_python','toggle_system'):
            # Map button id to section container id
            mapping = {
                'toggle_optional': 'section_optional',
                'toggle_python': 'section_python',
                'toggle_system': 'section_system'
            }
            sec = mapping.get(btn_id)
            if sec:
                try:
                    self._toggle_section(sec, btn_id)
                except Exception as e:
                    self._append_log(f'Failed to toggle section {sec}: {e}')
            return

    def _gather_params(self):
        name = self.query_one('#inst_name').value.strip() or 'stralyx'
        mem = self.query_one('#mem').value.strip() or '4G'
        cpus = self.query_one('#cpus').value.strip() or '2'
        disk = self.query_one('#disk').value.strip() or '20G'
        kde = self.query_one('#kde').value
        cal = self.query_one('#calamares').value
        install_python = False
        try:
            install_python = self.query_one('#install_python').value
        except Exception:
            install_python = False
        install_system = False
        try:
            install_system = self.query_one('#install_system').value
        except Exception:
            install_system = False
        elevate = False
        try:
            elevate = self.query_one('#elevate').value
        except Exception:
            elevate = False
        return dict(name=name, mem=mem, cpus=cpus, disk=disk, kde=kde, calamares=cal, install_python=install_python, install_system=install_system, elevate=elevate)

    def _toggle_section(self, section_id: str, btn_id: str):
        """Toggle visibility of a section Vertical container and update the button label."""
        try:
            btn = self.query_one(f'#{btn_id}', Button)
            sec = self.query_one(f'#{section_id}', Vertical)
        except Exception:
            # Textual may raise if not found; fallback to logging
            self._append_log(f'Section or button not found: {section_id} / {btn_id}')
            return
        # Toggle container visibility directly when possible
        try:
            current = getattr(sec, 'visible', True)
            sec.visible = not current
        except Exception:
            # fallback: toggle children visibility
            children = list(sec.children)
            any_visible = any(getattr(c, 'visible', True) for c in children)
            for c in children:
                try:
                    c.visible = not any_visible
                except Exception:
                    pass
            # reflect in sec.visible if supported
            try:
                sec.visible = not any_visible
            except Exception:
                pass

        # Update button label using a mapping to avoid string parsing
        titles = {
            'toggle_optional': 'Opcionales',
            'toggle_python': 'Python / UI',
            'toggle_system': 'Sistema'
        }
        title = titles.get(btn_id, btn_id)
        arrow = '▾' if getattr(sec, 'visible', True) else '▸'
        try:
            btn.label = f'{arrow} {title}'
        except Exception:
            pass
        # refresh the layout
        try:
            sec.refresh()
            btn.refresh()
        except Exception:
            pass

    def _run_action(self, action, params):
        if self.running:
            self._append_log('Another task is running; please wait or stop it first.')
            return
        self.running = True
        t = threading.Thread(target=self._worker, args=(action, params), daemon=True)
        t.start()

    def _worker(self, action, params):
        try:
            if action == 'build':
                cmd = [script_path('multipass-run.sh'), '--name', params['name'], '--mem', params['mem'], '--cpus', str(params['cpus']), '--disk', params['disk']]
                if params['kde']:
                    cmd.append('--with-kde')
                if params['calamares']:
                    cmd.append('--with-calamares')
            elif action == 'novnc':
                # image path is in inst_name field for novnc
                img = self.query_one('#inst_name').value.strip()
                if not img:
                    self.call_from_thread(self._append_log, 'Image path required for noVNC')
                    return
                cmd = [script_path('novnc-run.sh'), img]
            elif action == 'clean':
                cmd = [script_path('clean-build.sh'), '--yes', '--remove-instance', '--instance-name', params['name']]
            elif action == 'stop':
                cmd = [script_path('stop-novnc.sh')]
            elif action == 'check':
                # Ensure we invoke the Python entrypoint with the current interpreter
                cmd = [sys.executable, script_path('simetrio'), 'check']
            elif action == 'deps':
                # run simetrio deps; invoke with sys.executable to avoid permission issues
                cmd = [sys.executable, script_path('simetrio'), 'deps']
                if params.get('install_python'):
                    cmd.append('--install-python')
                if params.get('install_system'):
                    cmd.append('--install-binaries')
                if params.get('elevate'):
                    cmd.append('--elevate')
            else:
                self.call_from_thread(self._append_log, f'Unknown action: {action}')
                return

            # ensure executable
            try:
                # Only attempt to chmod repository scripts, never the Python interpreter
                first = cmd[0]
                fp = Path(first)
                if fp.exists() and str(fp) != str(Path(sys.executable)):
                    fp.chmod(fp.stat().st_mode | 0o111)
            except Exception:
                pass

            # run and stream output
            self.call_from_thread(self._append_log, f"Running: {' '.join(cmd)}")
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            for line in proc.stdout:
                self.call_from_thread(self._append_log, line.rstrip())
            proc.wait()
            self.call_from_thread(self._append_log, f'Process exited with {proc.returncode}')
        except Exception as e:
            self.call_from_thread(self._append_log, f'Worker error: {e}')
        finally:
            self.running = False

    # -- logging helpers -------------------------------------------------
    def _append_log(self, text: str):
        """Append text to the visual log and to the internal buffer."""
        if not hasattr(self, '_log_buffer'):
            self._log_buffer = []
        # keep buffer size reasonable
        for line in str(text).splitlines() or ['']:
            self._log_buffer.append(line)
            # limit buffer to last 5000 lines
            if len(self._log_buffer) > 5000:
                self._log_buffer.pop(0)
        try:
            # write to the TextLog widget
            if hasattr(self, 'textlog'):
                self.textlog.write(text)
        except Exception:
            pass

    def _copy_log_to_clipboard(self):
        """Copy internal log buffer to system clipboard with fallbacks."""
        data = '\n'.join(getattr(self, '_log_buffer', []))
        if not data:
            self._append_log('No log data to copy.')
            return
        system = platform.system()
        # macOS
        if system == 'Darwin':
            p = subprocess.Popen(['pbcopy'], stdin=subprocess.PIPE)
            p.communicate(input=data.encode())
            if p.returncode == 0:
                self._append_log('Log copied to clipboard (pbcopy).')
                return
        # Wayland
        if shutil.which('wl-copy'):
            p = subprocess.Popen(['wl-copy'], stdin=subprocess.PIPE)
            p.communicate(input=data.encode())
            if p.returncode == 0:
                self._append_log('Log copied to clipboard (wl-copy).')
                return
        # X11 xclip
        if shutil.which('xclip'):
            p = subprocess.Popen(['xclip', '-selection', 'clipboard'], stdin=subprocess.PIPE)
            p.communicate(input=data.encode())
            if p.returncode == 0:
                self._append_log('Log copied to clipboard (xclip).')
                return
        # fallback: write to temp file and notify
        fd, path = tempfile.mkstemp(prefix='simetrio-log-', suffix='.txt')
        with open(fd, 'w') as f:
            f.write(data)
        self._append_log(f'Clipboard utilities not found; log written to: {path}')

    # -- additional UI helpers -----------------------------------------
    def action_deps_flow(self):
        """Interactive deps flow: run deps check and ask user to install python reqs if missing."""
        # run check first
        self._append_log('Starting dependency check...')
        proc = subprocess.Popen([sys.executable, script_path('simetrio'), 'deps'], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        out = ''
        for line in proc.stdout:
            out += line
            self.call_from_thread(self._append_log, line.rstrip())
        proc.wait()

        if proc.returncode == 0:
            self.call_from_thread(self._append_log, 'All dependencies satisfied.')
            return

        # If missing python packages, offer to install
        if 'Missing Python packages' in out:
            self.call_from_thread(self._append_log, 'Missing Python packages detected. Attempting to install automatically...')
            # Determine if user requested elevation in the UI
            try:
                elevate = self.query_one('#elevate').value
            except Exception:
                elevate = False

            # Run installation flow using simetrio module functions, invoked via python -c
            try:
                install_system = self.query_one('#install_system').value
            except Exception:
                install_system = False

            # If requested, install system binaries first
            if install_system:
                cmd_sys = [sys.executable, '-c', (
                    "import simetrio,sys; rc=simetrio.install_system_binaries(bins=('multipass','qemu-system-x86_64'), elevate=%s); sys.exit(rc)"
                    % (str(elevate))) ]
                self.call_from_thread(self._append_log, f'Running system installer: {" ".join(cmd_sys)}')
                iproc = subprocess.Popen(cmd_sys, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                for line in iproc.stdout:
                    self.call_from_thread(self._append_log, line.rstrip())
                iproc.wait()
                if iproc.returncode != 0:
                    self.call_from_thread(self._append_log, f'System installation failed with {iproc.returncode}. Please install manually.')
                    return

            # Install Python requirements (elevated if requested)
            if elevate:
                cmd_py = [sys.executable, '-c', "import simetrio,sys; rc=simetrio.install_python_requirements_elevated(); sys.exit(rc)"]
            else:
                cmd_py = [sys.executable, '-c', "import simetrio,sys; rc=simetrio.install_python_requirements(); sys.exit(rc)"]
            self.call_from_thread(self._append_log, f'Running python installer: {" ".join(cmd_py)}')
            ppy = subprocess.Popen(cmd_py, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            for line in ppy.stdout:
                self.call_from_thread(self._append_log, line.rstrip())
            ppy.wait()
            if ppy.returncode != 0:
                self.call_from_thread(self._append_log, f'Python installation failed with {ppy.returncode}. Please install manually.')
                return

            # Re-run deps check
            self.call_from_thread(self._append_log, 'Re-checking dependencies after install...')
            rproc = subprocess.Popen([sys.executable, script_path('simetrio'), 'deps'], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            for line in rproc.stdout:
                self.call_from_thread(self._append_log, line.rstrip())
            rproc.wait()
            if rproc.returncode == 0:
                self.call_from_thread(self._append_log, 'Dependencies satisfied after installation.')
            else:
                self.call_from_thread(self._append_log, 'Dependencies remain missing after installation; please inspect output and install required system packages.')
            return

        # Detect if the CLI found a Multipass PKG and suggested manual installer step
        if 'Found Multipass PKG' in out or 'Multipass PKG present' in out:
            self.call_from_thread(self._append_log, 'Detected a downloaded Multipass PKG on macOS. This requires running the system installer to complete.')
            try:
                install_system = self.query_one('#install_system').value
            except Exception:
                install_system = False
            try:
                elevate = self.query_one('#elevate').value
            except Exception:
                elevate = False

            if not install_system:
                self.call_from_thread(self._append_log, 'Enable "Install system deps" in the options to allow the TUI to run the PKG installer.')
                return

            # require explicit double-confirmation to actually run the system installer
            if not self._pkg_install_pending:
                self._pkg_install_pending = True
                self.call_from_thread(self._append_log, 'To run the macOS PKG installer (requires admin) click "Run Selected" again to confirm.')
                return
            else:
                # user confirmed; reset flag and run the installer via simetrio CLI
                self._pkg_install_pending = False
                # Run the install_system_binaries function directly via python -c
                cmd_sys = [sys.executable, '-c', (
                    "import simetrio,sys; rc=simetrio.install_system_binaries(bins=('multipass','qemu-system-x86_64'), elevate=%s); sys.exit(rc)"
                    % (str(elevate)) )]
                self.call_from_thread(self._append_log, f'Running macOS PKG installer via: {" ".join(cmd_sys)}')
                iproc = subprocess.Popen(cmd_sys, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                for line in iproc.stdout:
                    self.call_from_thread(self._append_log, line.rstrip())
                iproc.wait()
                if iproc.returncode != 0:
                    self.call_from_thread(self._append_log, f'PKG installer run failed with {iproc.returncode}. Check logs in build/logs or ~/.cache/simetrio/logs')
                    return
                # re-run deps to confirm
                self.call_from_thread(self._append_log, 'Re-checking dependencies after PKG installer...')
                rproc = subprocess.Popen([sys.executable, script_path('simetrio'), 'deps'], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                for line in rproc.stdout:
                    self.call_from_thread(self._append_log, line.rstrip())
                rproc.wait()
                if rproc.returncode == 0:
                    self.call_from_thread(self._append_log, 'Dependencies satisfied after PKG installation.')
                else:
                    self.call_from_thread(self._append_log, 'Dependencies still missing after PKG installation; please inspect the logs and run manual steps if needed.')
                return

        # If binaries are missing and the user requested system install, attempt it
        if 'Missing binaries' in out:
            try:
                install_system = self.query_one('#install_system').value
            except Exception:
                install_system = False
            if install_system:
                self.call_from_thread(self._append_log, 'Attempting to install missing system binaries...')
                try:
                    elevate = self.query_one('#elevate').value
                except Exception:
                    elevate = False
                cmd_sys = [sys.executable, '-c', (
                    "import simetrio,sys; rc=simetrio.install_system_binaries(bins=('multipass','qemu-system-x86_64'), elevate=%s); sys.exit(rc)"
                    % (str(elevate)) )]
                self.call_from_thread(self._append_log, f'Running system install: {" ".join(cmd_sys)}')
                iproc = subprocess.Popen(cmd_sys, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                for line in iproc.stdout:
                    self.call_from_thread(self._append_log, line.rstrip())
                iproc.wait()
                if iproc.returncode != 0:
                    self.call_from_thread(self._append_log, f'System installation failed with {iproc.returncode}. Please install manually.')
                    return

                # Re-run deps check after system install
                self.call_from_thread(self._append_log, 'Re-checking dependencies after system install...')
                rproc = subprocess.Popen([sys.executable, script_path('simetrio'), 'deps'], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                for line in rproc.stdout:
                    self.call_from_thread(self._append_log, line.rstrip())
                rproc.wait()
                if rproc.returncode == 0:
                    self.call_from_thread(self._append_log, 'Dependencies satisfied after system installation.')
                else:
                    self.call_from_thread(self._append_log, 'Dependencies remain missing after system installation; please inspect output and install required system packages.')
                return

        # Fallback message
        self.call_from_thread(self._append_log, 'Some binaries are missing; please install them manually and re-run.')

    # Note: deps flow is started in the primary on_button_pressed handler above.

if __name__ == '__main__':
    # run the textual app; if terminal is too small textual will warn
    # Textual App __init__ may not accept a 'title' kwarg across versions; call without args.
    SimetrioApp().run()
