#!/usr/bin/env python3
"""Export the shared, secret-free OpenConfig runtime for Linux T3."""
import argparse
import hashlib
import json
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("output", type=Path)
parser.add_argument("--home", default="/opt/data")
args = parser.parse_args()
source = Path(__file__).resolve().parent
target = args.output.resolve()
target.mkdir(parents=True, exist_ok=True)
runtime = f"{args.home}/.config/opencode"
files = [source / name for name in ("AGENTS.md", "opencode.json", "oh-my-openagent.json", "versions.json")]
for directory in ("agents", "prompts", "profiles", "skills", "teams"):
    files.extend(p for p in (source / directory).rglob("*") if p.is_file() and p.suffix in (".md", ".json"))
manifest = {}
for path in sorted(files):
    if path.is_symlink():
        raise SystemExit(f"Refusing symlink in runtime export: {path}")
    relative = path.relative_to(source)
    text = path.read_text().replace("~/.config/opencode", runtime)
    if relative == Path("opencode.json"):
        config = json.loads(text)
        config["shell"] = "/bin/bash"
        config["instructions"] = [f"{runtime}/{p}" for p in config["instructions"]]
        config["skills"]["paths"] = [f"{runtime}/skills"]
        text = json.dumps(config, indent=2) + "\n"
    destination = target / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(text)
    manifest[str(relative)] = hashlib.sha256(text.encode()).hexdigest()
versions = json.loads((source / "versions.json").read_text())
(target / "manifest.json").write_text(json.dumps({
    "source": "jesseoue/opencode-configs", "version": versions["opencode_configs"],
    "opencode": versions["opencode"]["min"], "files": manifest,
}, indent=2) + "\n")
print(f"Exported OpenConfig {versions['opencode_configs']}: {len(manifest)} files to {target}")
