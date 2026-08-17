#!/usr/bin/env bash
# Auto-test for statusline-command.sh.
# Feeds synthetic payloads (same shape Claude Code sends) and asserts each
# segment of the rendered line. Caches are seeded in a throwaway HOME so the
# test is deterministic and makes NO API calls.
#
# Usage: bash test-statusline.sh
# Exit code 0 = all passed.

set -u

# Locate the script relative to this file so the test works from the repo too.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$SCRIPT_DIR/statusline-command.sh"
if [ ! -f "$SCRIPT" ]; then
  echo "FAIL  statusline script not found: $SCRIPT"
  exit 1
fi

# Throwaway HOME with seeded caches (prices TTL 6h, key/balance TTL 5min).
WORK=$(mktemp -d)
export HOME="$WORK"
# Python's expanduser() on Windows resolves "~" via USERPROFILE (not HOME),
# so point it at the same throwaway dir to keep the test deterministic.
export USERPROFILE="$WORK"
export HOMEDRIVE=""
export HOMEPATH=""
mkdir -p "$HOME/.claude/cache"
NOW=$(date +%s)

cat > "$HOME/.claude/cache/openrouter-prices.json" <<JSON
{"_fetched": $NOW, "models": {
  "deepseek/deepseek-v4-flash-0731": {
    "prompt": 0.00000014, "completion": 0.00000028,
    "cache_read": 0.000000028, "context": 1048576,
    "eff_prompt": 0.000000078596, "eff_completion": 0.000000157192,
    "eff_cache_read": 0.0000000157192, "eff_provider": "StreamLake"
  }
}}
JSON
cat > "$HOME/.claude/cache/openrouter-key.json" <<JSON
{"_fetched": $NOW, "daily": 2.50, "monthly": 17.75}
JSON
cat > "$HOME/.claude/cache/openrouter-balance.json" <<JSON
{"_fetched": $NOW, "balance": 10.00}
JSON

PASS=0; FAIL=0

check() { # name  got  expected-substring
  if printf '%s' "$2" | grep -qF "$3"; then
    echo "PASS  $1   contains: $3"
    PASS=$((PASS+1))
  else
    echo "FAIL  $1   want contains: $3"
    echo "      got: $(printf '%s' "$2" | tr '\n' ' ')"
    FAIL=$((FAIL+1))
  fi
}
no() { # name  got  forbidden-substring
  if printf '%s' "$2" | grep -qF "$3"; then
    echo "FAIL  $1   should NOT contain: $3"
    echo "      got: $(printf '%s' "$2" | tr '\n' ' ')"
    FAIL=$((FAIL+1))
  else
    echo "PASS  $1   no: $3"
    PASS=$((PASS+1))
  fi
}

# ---------- Case 1: empty payload (before any API call) -> silent, no crash
out=$(printf '' | bash "$SCRIPT" 2>/dev/null)
if [ -z "$out" ]; then
  echo "PASS  empty payload -> no output"
  PASS=$((PASS+1))
else
  echo "FAIL  empty payload -> expected silence, got: $(printf '%s' "$out" | tr '\n' ' ')"
  FAIL=$((FAIL+1))
fi

# ---------- Case 2: full payload, real model + real tokens
# used_percentage=78 comes from context_window_size=200000 (Claude Code's wrong
# fallback); the script must recompute % from the real 1M limit.
PAYLOAD='{
  "model": {"id": "deepseek/deepseek-v4-flash-0731", "display_name": "DeepSeek V4 Flash"},
  "context_window": {
    "total_input_tokens": 156600,
    "total_output_tokens": 291,
    "used_percentage": 78,
    "context_window_size": 200000,
    "current_usage": {"cache_creation_input_tokens": 0, "cache_read_input_tokens": 15500}
  }
}'
out=$(printf '%s' "$PAYLOAD" | bash "$SCRIPT" 2>/dev/null)

check "model label (slug)"      "$out" "V4-flash-0731"
check "key balance"              "$out" 'b $10.00'
check "daily spend"              "$out" 'd $2.50'
check "model price in/out"       "$out" 'P $0.0786 • $0.1572'
check "in/out tokens"            "$out" "in 156.6k / out 291"
check "cache +write ~read cost"  "$out" 'c +0 ~15.5k $0.0002'
check "ctx real limit 1M"        "$out" "ctx 156.6k/1M"
check "percent from real limit"  "$out" "(15%)"
no     "no wrong 78%"            "$out" "(78%)"
no     "no fake 200k limit"      "$out" "/200k"

# ---------- Case 3: payload with no context_window (before first call)
# Only model + balance/spend may show; no in/out, no cache, no ctx segments.
PAYLOAD='{"model": {"id": "deepseek/deepseek-v4-flash-0731"}}'
out=$(printf '%s' "$PAYLOAD" | bash "$SCRIPT" 2>/dev/null)
# price segment legitimately contains "in $x/M out $y/M", so assert on the
# token-specific marker " / out " (only the token segment has the slashes)
no "no token segment"   "$out" "/ out "
no "no cache segment"   "$out" "c +"

# ---------- Case 4: exactly 1M used -> '1M' suffix, 100%
PAYLOAD='{
  "model": {"id": "deepseek/deepseek-v4-flash-0731"},
  "context_window": {"total_input_tokens": 1048576, "total_output_tokens": 0,
    "used_percentage": 100, "context_window_size": 200000}
}'
out=$(printf '%s' "$PAYLOAD" | bash "$SCRIPT" 2>/dev/null)
check "ctx 1M/1M"  "$out" "ctx 1M/1M"
check "100%"       "$out" "(100%)"

# ---------- Case 5: fmt_tok edge values
out=$(printf '%s' '{"model": {"id": "deepseek/deepseek-v4-flash-0731"},
  "context_window": {"total_input_tokens": 1310720, "total_output_tokens": 999,
    "current_usage": {}}}' | bash "$SCRIPT" 2>/dev/null)
check "1.3M suffix" "$out" "in 1.3M / out 999"

rm -rf "$WORK"

echo
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
