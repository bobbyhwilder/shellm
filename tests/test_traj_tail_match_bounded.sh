#!/usr/bin/env bash
# traj tail --filter --match-bounded grows a backward window until N matches,
# without changing the old window-then-filter contract for plain --filter.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATH="$ROOT/bin:$PATH"

WORKDIR=$(mktemp -d /tmp/traj-tail-match-bounded.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT
TID=a1b2c3d4-e5f6-7890-abcd-ef1234567890
mkdir -p "$WORKDIR/$TID"

python3 - <<PY
import json
from pathlib import Path
p = Path("$WORKDIR/$TID/trajectory.jsonl")
rows = []
rows.append({"type":"thought","source":"monolith","content":"old-mono","step_id":"aaaaaaaa-0000-0000-0000-000000000001"})
for j in range(20):
    rows.append({"type":"idle","source":"watcher","content":"idle","step_id":f"bbbbbbbb-0000-0000-0000-{j:012d}"})
rows.append({"type":"observation","source":"monolith","content":"new-mono","step_id":"cccccccc-0000-0000-0000-000000000001"})
p.write_text("\n".join(json.dumps(r) for r in rows) + "\n")
print("wrote", p, "lines", len(rows))
PY

echo "---- plain --filter source=monolith -n 5 (window then filter; may miss buried) ----"
filter_out=$(traj tail --traj_dir "$WORKDIR" "$TID" --filter source=monolith -n 5 --raw --no-color || true)
python3 - <<PY
import json
raw = """$filter_out"""
rows = [json.loads(l) for l in raw.splitlines() if l.strip()]
got = [(r.get("source"), r.get("content")) for r in rows]
print("plain_filter", got)
# last 5 lines are 4 watcher idles + new-mono, so only new-mono survives
if got != [("monolith", "new-mono")]:
    raise SystemExit(f"expected plain --filter -n 5 to miss buried monolith, got {got}")
print("PLAIN_OK")
PY

echo "---- --filter source=monolith --match-bounded -n 2 (scan backward) ----"
bounded=$(traj tail --traj_dir "$WORKDIR" "$TID" --filter source=monolith --match-bounded -n 2 --raw --no-color)
python3 - <<PY
import json
raw = """$bounded"""
rows = [json.loads(l) for l in raw.splitlines() if l.strip()]
got = [(r.get("source"), r.get("content")) for r in rows]
print("bounded", got)
if got != [("monolith", "old-mono"), ("monolith", "new-mono")]:
    raise SystemExit(f"expected last 2 source=monolith = old-mono,new-mono got {got}")
print("BOUNDED_OK")
PY

echo "---- --filter source=monolith --match-bounded -n 1 (gap_refresh shape) ----"
one=$(traj tail --traj_dir "$WORKDIR" "$TID" --filter source=monolith --match-bounded -n 1 --raw --no-color)
python3 - <<PY
import json
raw = """$one""".strip()
row = json.loads(raw)
got = (row.get("source"), row.get("content"))
print("one", got)
if got != ("monolith", "new-mono"):
    raise SystemExit(f"expected last monolith = new-mono got {got}")
print("ONE_OK")
PY

echo "test_traj_tail_match_bounded: ok"
