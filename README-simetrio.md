Simetrio
========

Small wrapper CLI to orchestrate the repository build, noVNC run and cleanup flows.

Usage
-----

From repo root:

```
./scripts/simetrio check
./scripts/simetrio build --name stralyx --with-kde --with-calamares
./scripts/simetrio novnc build/Stralyx/output/debian-smoke.img
./scripts/simetrio stop
./scripts/simetrio clean --yes --remove-instance --instance-name stralyx
```

Design notes:
- Delegates to the existing bash scripts to preserve current behaviour and reduce duplication.
- Adds preflight checks and a single ergonomic entrypoint.

TUI (full-screen) instructions
------------------------------

The repository includes an optional full-screen colored TUI implemented with Textual.
Install dependencies and run:

```
python3 -m pip install -r scripts/requirements-simetrio.txt
./scripts/simetrio_tui.py
```

The TUI provides a larger, colored interface with parameter inputs and a live output pane.

