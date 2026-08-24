#!/usr/bin/env bash
# A2: cmd_append spills every oversized string field; cmd_show --full
# expands any *_ref from blobs/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATH="$ROOT/bin:$PATH"

WORKDIR=$(mktemp -d /tmp/traj-generic-spill.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT
TID=a2spill00-0000-4000-8000-000000000001
mkdir -p "$WORKDIR/$TID"

export SHELLM_STDOUT_INLINE_LIMIT=64

python3 - <<PY
import json
from pathlib import Path
p = Path("$WORKDIR/$TID/trajectory.jsonl")
p.write_text(json.dumps({"type":"thought","content":"seed","step_id":"aaaaaaaa-0000-0000-0000-000000000001"}) + "\n")
print("seeded", p)
PY

echo "---- spill content + command ----"
big_c=$(python3 -c 'print("C"*200)')
big_x=$(python3 -c 'print("X"*180)')
sid=$(traj append --traj_dir "$WORKDIR" "$TID" \
    --field type=prompt \
    --field content="$big_c" \
    --field command="$big_x" \
    --field run_id=run-a2)
echo "appended $sid"

python3 - <<PY
import json
from pathlib import Path
root = Path("$WORKDIR/$TID")
rows = [json.loads(l) for l in (root / "trajectory.jsonl").read_text().splitlines() if l.strip()]
row = next(r for r in rows if r.get("step_id") == "$sid")
print("keys", sorted(row))
assert row.get("content_truncated") is True, row
assert row.get("command_truncated") is True, row
assert row["content_bytes"] == 200
assert row["command_bytes"] == 180
assert row["content"] == "C"*64, len(row["content"])
assert row["command"] == "X"*64, len(row["command"])
assert row["type"] == "prompt"
assert row["run_id"] == "run-a2"
assert "type_ref" not in row
assert "run_id_ref" not in row
assert "step_id_ref" not in row
cref = root / row["content_ref"]
xref = root / row["command_ref"]
assert cref.is_file(), row["content_ref"]
assert xref.is_file(), row["command_ref"]
assert cref.read_text() == "C"*200
assert xref.read_text() == "X"*180
# last-line snapshot for the one-step --full traj
(root / "last.json").write_text(json.dumps(row) + "\n")
print("SPILL_OK")
PY

echo "---- --full expand on a one-step copy (show reads first step) ----"
SHOW_ID=a2show000-0000-4000-8000-000000000002
mkdir -p "$WORKDIR/$SHOW_ID/blobs"
python3 - <<PY
from pathlib import Path
src = Path("$WORKDIR/$TID")
dst = Path("$WORKDIR/$SHOW_ID")
last = (src / "last.json").read_text()
(dst / "trajectory.jsonl").write_text(last)
# copy referenced blobs
import json, shutil
row = json.loads(last)
for k, v in row.items():
    if k.endswith("_ref") and isinstance(v, str) and v:
        src_blob = src / v
        dst_blob = dst / v
        dst_blob.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src_blob, dst_blob)
print("show traj ready")
PY

got_c=$(traj show --traj_dir "$WORKDIR" "$SHOW_ID" --full --field content)
got_x=$(traj show --traj_dir "$WORKDIR" "$SHOW_ID" --full --field command)
python3 - <<PY
got_c = """$got_c"""
got_x = """$got_x"""
assert got_c == "C"*200, (len(got_c), got_c[:80])
assert got_x == "X"*180, (len(got_x), got_x[:80])
print("EXPAND_OK")
PY

# truncated (no --full) stays clipped
clip=$(traj show --traj_dir "$WORKDIR" "$SHOW_ID" --field content)
python3 - <<PY
clip = """$clip"""
assert clip == "C"*64, (len(clip), clip[:80])
print("INLINE_STAYS_CLIPPED_OK")
PY

echo "---- stdout still spills when large ----"
big_out=$(python3 -c 'print("O"*120)')
sid2=$(traj append --traj_dir "$WORKDIR" "$TID" --field type=exec --field stdout="$big_out")
python3 - <<PY
import json
from pathlib import Path
root = Path("$WORKDIR/$TID")
rows = [json.loads(l) for l in (root / "trajectory.jsonl").read_text().splitlines() if l.strip()]
row = next(r for r in rows if r.get("step_id") == "$sid2")
assert row.get("stdout_truncated") is True
assert row["stdout_bytes"] == 120
assert row["stdout"] == "O"*64
assert (root / row["stdout_ref"]).read_text() == "O"*120
print("STDOUT_STILL_OK")
PY

# expand stdout via one-step copy
SHOW2=a2show000-0000-4000-8000-000000000003
mkdir -p "$WORKDIR/$SHOW2/blobs"
python3 - <<PY
import json, shutil
from pathlib import Path
src = Path("$WORKDIR/$TID")
dst = Path("$WORKDIR/$SHOW2")
rows = [json.loads(l) for l in (src / "trajectory.jsonl").read_text().splitlines() if l.strip()]
row = next(r for r in rows if r.get("step_id") == "$sid2")
(dst / "trajectory.jsonl").write_text(json.dumps(row) + "\n")
for k, v in row.items():
    if k.endswith("_ref") and isinstance(v, str) and v:
        (dst / v).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src / v, dst / v)
PY
got_o=$(traj show --traj_dir "$WORKDIR" "$SHOW2" --full --field stdout)
python3 - <<PY
got_o = """$got_o"""
assert got_o == "O"*120, (len(got_o), got_o[:80])
print("EXPAND_STDOUT_OK")
PY

echo "---- non-string fields are not spilled (disk-level object) ----"
python3 - <<PY
import json
from pathlib import Path
# The spill helper only walks string-valued keys. Confirm a fat object
# written directly (append CLI is string-only) has no usage_ref.
root = Path("$WORKDIR/$TID")
p = root / "trajectory.jsonl"
obj = {"nested": "Y"*200, "n": 1}
row = {"type":"usage","usage": obj, "step_id":"cccccccc-0000-0000-0000-000000000009"}
with p.open("a") as f:
    f.write(json.dumps(row) + "\n")
# Re-read: still an object, no usage_ref. This documents the contract;
# cmd_append never stringifies objects.
got = json.loads(p.read_text().splitlines()[-1])
assert isinstance(got["usage"], dict)
assert "usage_ref" not in got
print("OBJECT_INLINE_OK")
PY


echo "---- search follows content_ref / command_ref, not just stdout ----"
# Needle lives only past the inline clip so a prefix-only search would miss it.
export SHELLM_STDOUT_INLINE_LIMIT=80
SID_S=$(traj append --traj_dir "$WORKDIR" "$TID" \
  --field type=thought \
  --field content="$(python3 -c 'print("PREFIX"+"p"*80+"NEEDLE_CONTENT_ONLY")')" \
  --field command="$(python3 -c 'print("CMD"+"q"*80+"NEEDLE_COMMAND_ONLY")')")
hits_c=$(traj search --traj_dir "$WORKDIR" NEEDLE_CONTENT_ONLY "$TID" || true)
hits_x=$(traj search --traj_dir "$WORKDIR" NEEDLE_COMMAND_ONLY "$TID" || true)
hits_miss=$(traj search --traj_dir "$WORKDIR" NEEDLE_NOWHERE "$TID" || true)
HITS_C="$hits_c" HITS_X="$hits_x" HITS_MISS="$hits_miss" SID_S="$SID_S" python3 - <<'PY2'
import os
hits_c = os.environ["HITS_C"]
hits_x = os.environ["HITS_X"]
hits_miss = os.environ["HITS_MISS"]
sid = os.environ["SID_S"]
assert "NEEDLE_CONTENT_ONLY" in hits_c, hits_c
assert sid in hits_c, hits_c
assert "NEEDLE_COMMAND_ONLY" in hits_x, hits_x
assert sid in hits_x, hits_x
assert not hits_miss.strip(), hits_miss
print("SEARCH_REFS_OK")
PY2

echo "test_traj_generic_spill: ok"
