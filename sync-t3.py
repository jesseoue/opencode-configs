#!/usr/bin/env python3
"""Synchronize only the local T3 OpenCode instance with the shared catalog."""
import json
import os
import shutil
import time
from pathlib import Path

root = Path(__file__).resolve().parent
spec = json.loads((root / "t3-opencode.json").read_text())
path = Path.home() / ".t3/userdata/settings.json"
settings = json.loads(path.read_text()) if path.exists() else {}
instance = settings.setdefault("providerInstances", {}).setdefault("opencode", {})
instance.update(driver="opencode", enabled=True)
config = instance.setdefault("config", {})
catalog = spec.get("catalogModels", spec["customModels"])
custom = [model for model in config.get("customModels", []) if model not in catalog]
config.update(binaryPath=str(Path(spec["binaryPath"]).expanduser()),
              serverUrl=spec["serverUrl"], customModels=custom)
settings.setdefault("providers", {}).setdefault("opencode", {})["enabled"] = True
payload = json.dumps(settings, indent=2) + "\n"
if path.exists() and json.loads(path.read_text()) == settings:
    print("Local T3 OpenCode already matches the shared configuration.")
else:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        backup = path.with_name(f"settings.before-openconfig-{time.time_ns()}.json")
        shutil.copy2(path, backup)
        backup.chmod(0o600)
    temporary = path.with_suffix(".openconfig.tmp")
    temporary.write_text(payload)
    temporary.chmod(0o600)
    os.replace(temporary, path)
    print("Updated the local T3 OpenCode instance; other provider settings preserved.")
