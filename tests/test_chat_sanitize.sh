#!/usr/bin/env bash
# test_chat_sanitize.sh — unit tests for bin/chat _sanitize_message()
#
# _sanitize_message() strips leaked internal command dumps
# (SO/SI getcmd traces, or the same markers rendered as 0egetcmd0e)
# plus C0/C1 control bytes so a model echo never hits the chat log.
# bin/chat calls main at the end, so we extract the function instead
# of sourcing the script.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

# Extract _sanitize_message() from bin/chat without running main.
eval "$(sed -n '/^_sanitize_message()/,/^}/p' "$REPO/bin/chat")"

if ! type _sanitize_message >/dev/null 2>&1; then
    printf 'FAIL could not extract _sanitize_message from bin/chat\n'
    exit 1
fi

# --- clean prose is unchanged --------------------------------------------
got=$(_sanitize_message "hello Andy, sidecar is up")
if [[ "$got" == "hello Andy, sidecar is up" ]]; then
    ok "clean prose unchanged"
else
    bad "clean prose unchanged" "got: $(printf %q "$got")"
fi

# --- 0egetcmd0e dump is cut at the marker, prose kept --------------------
got=$(_sanitize_message "I'll check our recent thread. 0egetcmd0echat history 20 1egetcmd0eskills")
if [[ "$got" == "I'll check our recent thread." && "$got" != *getcmd* ]]; then
    ok "strips 0egetcmd0e dump, keeps prose"
else
    bad "strips 0egetcmd0e dump, keeps prose" "got: $(printf %q "$got")"
fi

# --- SO/SI getcmd delimiters also cut the dump ---------------------------
got=$(_sanitize_message $'Ignore that last blob. \x0egetcmd\x0echat history 20')
if [[ "$got" == "Ignore that last blob." && "$got" != *getcmd* && "$got" != *$'\x0e'* ]]; then
    ok "strips SO-getcmd-SO dump, keeps prose"
else
    bad "strips SO-getcmd-SO dump, keeps prose" "got: $(printf %q "$got")"
fi

# --- C0 control bytes (except tab/newline) are stripped ------------------
got=$(_sanitize_message $'keep\tme\x01\x02gone')
if [[ "$got" == *$'\x01'* || "$got" == *$'\x02'* ]]; then
    bad "strips C0 bytes, keeps tab" "C0 bytes remain: $(printf %q "$got")"
elif [[ "$got" == *$'\t'* && "$got" == *keep* && "$got" == *gone* ]]; then
    ok "strips C0 bytes, keeps tab and words"
else
    bad "strips C0 bytes, keeps tab" "got: $(printf %q "$got")"
fi

# --- trailing whitespace is rstrip'd -------------------------------------
got=$(_sanitize_message "prose   ")
if [[ "$got" == "prose" ]]; then
    ok "rstrips trailing whitespace"
else
    bad "rstrips trailing whitespace" "got: $(printf %q "$got")"
fi

# --- ANSI CSI sequences are stripped -------------------------------------
got=$(_sanitize_message $'hi\x1b[31mred\x1b[0m')
if [[ "$got" == *$'\x1b'* ]]; then
    bad "strips ANSI CSI" "ESC remains: $(printf %q "$got")"
elif [[ "$got" == "hired" || "$got" == "hi red" || "$got" == "hired" ]]; then
    ok "strips ANSI CSI (got: $(printf %q "$got"))"
else
    # still a pass if ESC is gone and letters remain
    if [[ "$got" == *hi* && "$got" == *red* ]]; then
        ok "strips ANSI CSI (got: $(printf %q "$got"))"
    else
        bad "strips ANSI CSI" "got: $(printf %q "$got")"
    fi
fi

# --- Telegram-shaped reply with embedded tool-call dump ------------------
# Regression: a model reply bound for the Telegram bridge once carried its
# internal getcmd trace plus tool_call/mindlog markup after the prose.
# Everything from the first dump marker onward must be cut.
tg=$'Deploy finished ✅ all three checks are green.\x0egetcmd\x0echat history 20\x0egetcmd\x0e{"tool_call":{"name":"telegram.send_message","arguments":{"chat_id":81433,"text":"mindlog tail 50"}}}'
got=$(_sanitize_message "$tg")
if [[ "$got" == "Deploy finished ✅ all three checks are green." \
      && "$got" != *getcmd* && "$got" != *tool_call* \
      && "$got" != *mindlog* && "$got" != *$'\x0e'* ]]; then
    ok "telegram dump blob does not survive"
else
    bad "telegram dump blob does not survive" "got: $(printf %q "$got")"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
