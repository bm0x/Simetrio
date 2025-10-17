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
    from textual.app import App, ComposeResult
    from textual.widgets import Header, Footer, Button, Static, Input, Checkbox, TextLog
    from textual.containers import Horizontal, Vertical
    from textual.reactive import var
except Exception:
    print("Textual is not installed. Install dependencies with:")
    print("  python3 -m pip install -r scripts/requirements-simetrio.txt")
    sys.exit(1)

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = REPO_ROOT / 'scripts'

# Helper to ensure scripts exist
def script_path(name):
    p = SCRIPTS_DIR / name
    if not p.exists():
        raise FileNotFoundError(f"Required script not found: {p}")
    return str(p)

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
                yield Button("Quit", id="quit")
            with Vertical(id="right", classes="panel"):
                yield Static("Parameters", id="params_title")
                yield Input(placeholder="Instance name (default: stralyx)", id="inst_name")
                yield Input(placeholder="Memory (e.g. 4G)", id="mem")
                yield Input(placeholder="CPUs (e.g. 2)", id="cpus")
                yield Input(placeholder="Disk (e.g. 20G)", id="disk")
                yield Checkbox(label="Install KDE", id="kde")
                yield Checkbox(label="Install Calamares", id="calamares")
                yield Button("Run Selected", id="run_selected")
                yield Button("Copy Log", id="copy_log")
            with Vertical(id="log", classes="panel"):
                yield Static("Output", id="log_title")
                self.textlog = TextLog(highlight=True, wrap=True, id="textlog")
                yield self.textlog
        yield Footer()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        btn_id = event.button.id
        if btn_id == 'quit':
            self.exit()
            return
        if btn_id in ('build','novnc','clean','stop','check'):
            # mark which action to run; show selection in log
            self.action = btn_id
            self._append_log(f"Selected action: {btn_id}")
            if btn_id == 'novnc':
                # prompt for image path via input focus
                self.query_one('#inst_name').value = ''
                self.query_one('#inst_name').placeholder = 'Image path (e.g. build/Stralyx/output/debian-smoke.img)'
            else:
                self.query_one('#inst_name').placeholder = 'Instance name (default: stralyx)'
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
                self._run_action(action, params)
            except Exception as e:
                self._append_log(f'Error preparing action: {e}')

    def _gather_params(self):
        name = self.query_one('#inst_name').value.strip() or 'stralyx'
        mem = self.query_one('#mem').value.strip() or '4G'
        cpus = self.query_one('#cpus').value.strip() or '2'
        disk = self.query_one('#disk').value.strip() or '20G'
        kde = self.query_one('#kde').value
        cal = self.query_one('#calamares').value
        return dict(name=name, mem=mem, cpus=cpus, disk=disk, kde=kde, calamares=cal)

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
                cmd = [script_path('simetrio'), 'check']
            else:
                self.call_from_thread(self._append_log, f'Unknown action: {action}')
                return

            # ensure executable
            try:
                for p in cmd[:1]:
                    Path(p).chmod(Path(p).stat().st_mode | 0o111)
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

if __name__ == '__main__':
    # run the textual app; if terminal is too small textual will warn
    # Textual App __init__ may not accept a 'title' kwarg across versions; call without args.
    SimetrioApp().run()
