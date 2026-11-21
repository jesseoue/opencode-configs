#!/usr/bin/env python3
"""Prepare a credential-free installed configuration for repository CI checks."""
import argparse
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
print("Prepared credential-free OpenConfig runtime fixture")
