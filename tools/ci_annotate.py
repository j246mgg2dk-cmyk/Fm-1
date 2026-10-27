#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""CI helper (this fork): put a failed step's important lines in one GitHub annotation, so they can be read from the
checks API when the log download is not reachable.  tools/ci_annotate.py TITLE LOG"""
import re
import sys

title, path = sys.argv[1], sys.argv[2]
lines = open(path, errors="replace").read().splitlines()
hit = [ln for ln in lines if re.search(r"FAIL|error|Error|failed|warning: .*\[-W|overflow|exceeds|headroom", ln)]
pick = hit[:40] + ["--- tail ---"] + lines[-25:]
msg = "%0A".join(ln.replace("%", "%25").replace("\r", "")[:300] for ln in pick)
print(f"::error title={title}::{msg}")
