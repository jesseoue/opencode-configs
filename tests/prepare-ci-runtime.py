#!/usr/bin/env python3
"""Prepare a credential-free installed configuration for repository CI checks."""
import argparse
import json
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--home", type=Path, default=Path.home())
args = parser.parse_args()
repo = Path(__file__).resolve().parents[1]
config = args.home / ".config/opencode"
config.parent.mkdir(parents=True, exist_ok=True)
if config.exists() or config.is_symlink():
    if config.resolve() != repo:
        raise SystemExit("Refusing to replace another installed configuration")
else:
    config.symlink_to(repo, target_is_directory=True)
omo = args.home / ".omo/omo.jsonc"
omo.parent.mkdir(parents=True, exist_ok=True)
plugin = json.loads((repo / "oh-my-openagent.json").read_text())
payload = json.dumps({"$schema": plugin["$schema"], "[opencode]": plugin}, indent=2) + "\n"
if omo.exists() and omo.read_text() != payload:
    raise SystemExit("Refusing to replace an existing OmO configuration")
omo.write_text(payload)
omo.chmod(0o600)
print("Prepared credential-free OpenConfig runtime fixture")
