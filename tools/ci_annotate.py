#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""CI helper (this fork): a failed step's important lines as GitHub annotations (each under 4 KB, at most 9), so
they can be read from the checks API when the log download is not reachable.  tools/ci_annotate.py TITLE LOG"""
import re
import sys

title, path = sys.argv[1], sys.argv[2]
lines = open(path, errors="replace").read().splitlines()
pat = re.compile(r"FAIL|failed|over budget|exceeds|headroom|undefined reference|error:|Error:|Traceback|not ok|!=|fatal|rejected|denied|cannot|No such")
hit = [f"{i}: {ln}" for i, ln in enumerate(lines)
       if pat.search(ln) and "warning:" not in ln and not ln.rstrip().endswith(" ok")]
tail = [f"{len(lines) - 15 + i}: {ln}" for i, ln in enumerate(lines[-15:])]
chunks, cur = [], []
for ln in hit[:200] + ["--- tail ---"] + tail:
    ln = ln.replace("%", "%25").replace("\r", "")[:240]
    if sum(len(x) + 3 for x in cur) + len(ln) > 3600:
        chunks.append(cur)
        cur = []
    cur.append(ln)
chunks.append(cur)
for k, c in enumerate(chunks if len(chunks) <= 9 else chunks[:8] + chunks[-1:]):
    print(f"::error title={title} {k + 1}::" + "%0A".join(c))
