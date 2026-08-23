#!/usr/bin/env bash
# A3: traj tail --types grows a backward window until N type-matches.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATH="$ROOT/bin:$PATH"

WORKDIR=$(mktemp -d /tmp/traj-tail-types.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT
TID=12c46a51-895c-420c-9a8b-d959082bab88
mkdir -p "$WORKDIR/$TID"

python3 - <<PY
import json
from pathlib import Path
p = Path("$WORKDIR/$TID/trajectory.jsonl")
rows = []
for i in range(3):
    rows.append({"type":"thought","content":f"t{i}","step_id":f"aaaaaaaa-0000-0000-0000-{i:012d}"})
    for j in range(6):
        rows.append({"type":"idle","content":"idle","step_id":f"bbbbbbbb-0000-0000-0000-{i*10+j:012d}"})
p.write_text("\n".join(json.dumps(r) for r in rows) + "\n")
print("wrote", p, "lines", len(rows))
PY

echo "---- --filter type=thought -n 3 (old: last 3 lines, then filter) ----"
filter_out=$(traj tail --traj_dir "$WORKDIR" "$TID" --filter type=thought -n 3 --raw --no-color || true)
filter_count=$(printf '%s\n' "$filter_out" | grep -c . || true)
echo "filter_count $filter_count"
if [[ "$filter_count" -ne 0 ]]; then
  echo "expected old --filter -n 3 to miss buried thoughts (got $filter_count)" >&2
  exit 1
fi

echo "---- --types thought -n 3 (new: last 3 thoughts even if buried) ----"
types_out=$(traj tail --traj_dir "$WORKDIR" "$TID" --types thought -n 3 --raw --no-color)
python3 - <<PY
import json, os, sys
raw = """$types_out"""
rows = [json.loads(l) for l in raw.splitlines() if l.strip()]
got = [r.get("content") for r in rows]
print("count", len(rows), got)
if got != ["t0", "t1", "t2"]:
    raise SystemExit(f"expected last 3 thoughts t0 t1 t2, got {got}")
print("TYPES_OK")
PY

echo "---- --types thought,observation -n 2 (multi-type) ----"
# add two observations at the end after more idle
python3 - <<PY
import json
from pathlib import Path
p = Path("$WORKDIR/$TID/trajectory.jsonl")
rows = [json.loads(l) for l in p.read_text().splitlines() if l.strip()]
rows.append({"type":"observation","content":"o1","step_id":"cccccccc-0000-0000-0000-000000000001"})
rows.append({"type":"idle","content":"idle","step_id":"cccccccc-0000-0000-0000-000000000002"})
rows.append({"type":"observation","content":"o2","step_id":"cccccccc-0000-0000-0000-000000000003"})
p.write_text("\n".join(json.dumps(r) for r in rows) + "\n")
PY
multi=$(traj tail --traj_dir "$WORKDIR" "$TID" --types thought,observation -n 2 --raw --no-color)
python3 - <<PY
import json
raw = """$multi"""
rows = [json.loads(l) for l in raw.splitlines() if l.strip()]
got = [(r.get("type"), r.get("content")) for r in rows]
print("multi", got)
if got != [("observation","o1"), ("observation","o2")]:
    raise SystemExit(f"expected last 2 thought|observation = o1,o2 got {got}")
print("MULTI_OK")
PY

echo "test_traj_tail_types: ok"
