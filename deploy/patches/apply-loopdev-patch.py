#!/usr/bin/env python3
"""Patch pi-gen's ensure_next_loopdev function for Podman compatibility."""
import re
import sys

patch_file = sys.argv[1]
common_file = sys.argv[2]

patch = open(patch_file).read().strip()
common = open(common_file).read()

# Match the original function up to the closing brace + newline before export
pattern = re.compile(
    r'ensure_next_loopdev\(\) \{.*?\}\n(?=export -f ensure_next_loopdev)',
    re.DOTALL,
)

match = pattern.search(common)
if not match:
    print("Warning: ensure_next_loopdev not found in scripts/common, skipping patch")
    sys.exit(0)

# Replace using string slicing to avoid regex replacement escaping issues
common = common[: match.start()] + patch + "\n" + common[match.end() :]
open(common_file, "w").write(common)
print("Patched ensure_next_loopdev in scripts/common")
