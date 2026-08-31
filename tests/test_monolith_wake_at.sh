#!/usr/bin/env bash
# test_monolith_wake_at.sh -- monolith spontaneity wake re-arm regressions.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ -- $2}"; }

TMP=$(mktemp -d)
TRAJ_ID="cafe0000-0000-0000-0000-000000000002"
TRAJ_FILE="$TMP/id/trajectories/$TRAJ_ID/trajectory.jsonl"

cleanup() {
    rm -rf "$TMP"
}
trap cleanup EXIT

setup_identity() {
    rm -rf "$TMP/id" "$TMP/bin"
    mkdir -p "$TMP/id/run" "$TMP/id/workdir" "$TMP/id/memories" \
        "$TMP/id/skills" "$TMP/id/kernel" "$(dirname "$TRAJ_FILE")" "$TMP/bin"
    printf 'name=testid\ncreated=test\nroot_trajectory=%s\n' "$TRAJ_ID" > "$TMP/id/info.txt"
    : > "$TRAJ_FILE"

    cat > "$TMP/bin/identity" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "prompt" ]] && exit 0
exit 0
EOF
    cat > "$TMP/bin/skills" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "prompt" ]] && exit 0
exit 0
EOF
    cat > "$TMP/bin/shellm" <<'EOF'
#!/usr/bin/env bash
[[ -n "${SHELLM_RUN_ID_OUT:-}" ]] && printf 'fake-run\n' > "$SHELLM_RUN_ID_OUT"
if [[ -n "${SHELLM_PROMPT_OUT:-}" && $# -gt 0 ]]; then
    eval "last=\${$#}"
    printf '%s\n' "$last" > "$SHELLM_PROMPT_OUT"
fi
if [[ -n "${SHELLM_WAKE_OUT:-}" ]]; then
    printf '%s\n' "${SHELLM_WAKE:-}" > "$SHELLM_WAKE_OUT"
fi
exit 0
EOF
    cat > "$TMP/bin/traj" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    exists)
        exit 1
        ;;
    path)
        printf '%s\n' "$TRAJ_FILE"
        ;;
    append)
        cat >> "$TRAJ_FILE"
        printf '\n' >> "$TRAJ_FILE"
        ;;
    *)
        exit 0
        ;;
esac
EOF
    chmod +x "$TMP/bin/identity" "$TMP/bin/skills" "$TMP/bin/shellm" "$TMP/bin/traj"
}

run_monolith_step() {
    PATH="$TMP/bin:$REPO/bin:$PATH" \
    IDENTITY_DIR="$TMP/id" \
    IDENTITY_NAME=testid \
    TRAJ_DIR="$TMP/id/trajectories" \
    TRAJ_ID="$TRAJ_ID" \
    TRAJ_FILE="$TRAJ_FILE" \
    MEM_DIR="$TMP/id/memories" \
    SKILLS_DIR="$TMP/id/skills" \
    SKILLS_KERNEL_DIR="$TMP/id/kernel" \
    MONOLITH_TIERED_MEMORY=0 \
    MONOLITH_BACKOFF_BASE=5 \
    MONOLITH_BACKOFF_FACTOR=2 \
    MONOLITH_BACKOFF_CAP=300 \
    MONOLITH_BACKOFF_HOLD=3 \
    SHELLM_PROMPT_OUT="${SHELLM_PROMPT_OUT:-$TMP/last_prompt.txt}" \
    SHELLM_WAKE_OUT="${SHELLM_WAKE_OUT:-$TMP/last_wake.txt}" \
    "$REPO/thinkers/monolith/step"
}

read_wake_at() {
    cat "$TMP/id/run/monolith.wake_at" 2>/dev/null
}

test_noop_wake_rearms_with_backoff_default() {
    setup_identity
    printf '{"level":3,"ticks_at_level":0}\n' > "$TMP/id/run/monolith_backoff_state.json"
    rm -f "$TMP/id/run/dispatcher.token" "$TMP/id/run/monolith.wake_at"

    local before after wake_at
    before=$(date +%s)
    printf '{"type":"message","content":"ignored","source":"chat"}' | run_monolith_step
    after=$(date +%s)
    wake_at=$(read_wake_at)

    if [[ "$wake_at" =~ ^[0-9]+$ ]] && (( wake_at >= before + 20 && wake_at <= after + 20 )); then
        ok "early no-op message wake re-arms at current backoff delay"
    else
        bad "early no-op message wake re-arms at current backoff delay" "wake_at=$wake_at before=$before after=$after"
    fi
}

test_missing_dispatcher_token_still_writes_wake_at() {
    setup_identity
    rm -f "$TMP/id/run/dispatcher.token" "$TMP/id/run/monolith.wake_at"

    local wake_at
    printf '{"type":"monolith-wake","content":"wake","source":"monolith-timer"}' | run_monolith_step
    wake_at=$(read_wake_at)

    if [[ "$wake_at" =~ ^[0-9]+$ ]]; then
        ok "monolith wake writes wake_at without dispatcher.token"
    else
        bad "monolith wake writes wake_at without dispatcher.token" "wake_at=$wake_at"
    fi
}

test_own_observation_noop_rearms() {
    setup_identity
    rm -f "$TMP/id/run/dispatcher.token" "$TMP/id/run/monolith.wake_at"

    local wake_at
    printf '{"type":"observation","content":"own","source":"monolith"}' | run_monolith_step
    wake_at=$(read_wake_at)

    if [[ "$wake_at" =~ ^[0-9]+$ ]]; then
        ok "own-step defensive no-op re-arms wake_at"
    else
        bad "own-step defensive no-op re-arms wake_at" "wake_at=$wake_at"
    fi
}

test_reactive_observation_is_wake_seed() {
    setup_identity
    rm -f "$TMP/last_prompt.txt" "$TMP/last_wake.txt"

    printf '{"type":"observation","content":"mailbox: hermes ticket about orientation probe","source":"hermes-maintenance"}' | run_monolith_step

    if [[ ! -s "$TMP/last_prompt.txt" ]]; then
        bad "reactive observation invokes shellm with a prompt" "missing prompt capture"
        return
    fi

    local prompt wake
    prompt=$(cat "$TMP/last_prompt.txt")
    wake=$(cat "$TMP/last_wake.txt" 2>/dev/null)

    local head
    head=$(printf '%s' "$prompt" | head -c 4096)
    if printf '%s\n' "$head" | grep -q "REACTIVE wake from hermes-maintenance" \
        && printf '%s\n' "$head" | grep -q "wake seed: mailbox: hermes ticket about orientation probe" \
        && printf '%s\n' "$head" | grep -q "This observation is the job" \
        && printf '%s\n' "$head" | grep -q "Choose ONE function" \
        && printf '%s\n' "$wake" | grep -q "reactive/observation:hermes-maintenance"; then
        ok "reactive observation surfaces as wake seed in first 4096 bytes"
    else
        bad "reactive observation surfaces as wake seed in first 4096 bytes" "wake=$wake prompt_head=$(printf '%s' "$head" | head -c 500)"
    fi
}

test_spontaneous_wake_has_no_reactive_seed() {
    setup_identity
    rm -f "$TMP/last_prompt.txt" "$TMP/last_wake.txt"

    printf '{"type":"monolith-wake","content":"wake","source":"monolith-timer"}' | run_monolith_step

    if [[ ! -s "$TMP/last_prompt.txt" ]]; then
        bad "spontaneous wake invokes shellm with a prompt" "missing prompt capture"
        return
    fi
    if grep -q "REACTIVE wake" "$TMP/last_prompt.txt"; then
        bad "spontaneous wake should not carry a reactive seed" "prompt_head=$(head -c 400 "$TMP/last_prompt.txt")"
    else
        ok "spontaneous wake does not inject a reactive observation seed"
    fi
}

test_noop_wake_rearms_with_backoff_default
test_missing_dispatcher_token_still_writes_wake_at
test_own_observation_noop_rearms
test_reactive_observation_is_wake_seed
test_spontaneous_wake_has_no_reactive_seed

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
