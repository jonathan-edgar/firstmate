#!/usr/bin/env bash
# Behavior tests for bin/fm-token-usage.sh - the claude token-accounting helper.
#
# The helper sums per-message token usage from claude's own session transcripts,
# which live at:
#   $FM_CLAUDE_PROJECTS_DIR/<encoded-cwd>/<session>.jsonl              main agent
#   $FM_CLAUDE_PROJECTS_DIR/<encoded-cwd>/<session>/subagents/*.jsonl  subagents
# where <encoded-cwd> is the absolute cwd with every '/' and '.' turned into '-'.
# These cases pin the contract hermetically over synthetic transcripts:
#   (a) task-id mode sums main + subagents from state/<id>.meta's worktree
#   (b) non-claude harness is refused with exit 3
#   (c) --json emits the machine object
#   (d) default scoping counts only the NEWEST session; --all counts every one
#   (e) --cwd mode works without a task/meta
#   (f) a cwd with no transcripts exits 4
#   (g) malformed / non-usage lines contribute nothing (guarded)
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-token-usage.sh"
command -v jq >/dev/null 2>&1 || { echo "1..0 # SKIP jq not installed"; exit 0; }

TMP=$(fm_test_tmproot fm-token-usage)
HOME_DIR="$TMP/home"
PROJECTS="$TMP/projects"
mkdir -p "$HOME_DIR/state" "$PROJECTS"

# A synthetic crewmate worktree path (need not exist; only its encoding matters).
CWD="$TMP/wt/discogs-rn-app"
enc=$(printf '%s' "$CWD" | tr './' '-')
PROJDIR="$PROJECTS/$enc"

usage_line() { # <in> <out> <cc> <cr>
  printf '{"type":"assistant","message":{"role":"assistant","usage":{"input_tokens":%d,"output_tokens":%d,"cache_creation_input_tokens":%d,"cache_read_input_tokens":%d}}}\n' "$1" "$2" "$3" "$4"
}

# --- build a session: main jsonl (2 usage lines + guard lines) + 1 subagent ---
mkdir -p "$PROJDIR/sess-main/subagents"
{
  echo '{"type":"summary","summary":"no message here"}'   # guard: no .message
  usage_line 10 20 5 100
  echo '{"message":"plain string message"}'               # guard: .message is a string, INTERLEAVED
  echo '{"type":"user","message":{"role":"user","content":"hi"}}'  # guard: message but no usage, INTERLEAVED
  usage_line 1 2 0 50
} > "$PROJDIR/sess-main.jsonl"
usage_line 3 4 7 200 > "$PROJDIR/sess-main/subagents/agent-x.jsonl"
# main: in=11 out=22 cc=5 cr=150 ; sub: in=3 out=4 cc=7 cr=200
# totals: in=14 out=26 cc=12 cr=350 -> grand=402

fm_write_meta "$HOME_DIR/state/tok-a.meta" "worktree=$CWD" "harness=claude" "kind=ship"

export FM_HOME="$HOME_DIR"
export FM_CLAUDE_PROJECTS_DIR="$PROJECTS"

# (a) task-id mode sums main + subagents
out=$("$TOOL" tok-a); code=$?
expect_code 0 "$code" "task-id mode should succeed"
assert_contains "$out" "input                     14" "(a) input total wrong"
assert_contains "$out" "output                    26" "(a) output total wrong"
assert_contains "$out" "cache-create              12" "(a) cache-create total wrong"
assert_contains "$out" "cache-read               350" "(a) cache-read total wrong"
assert_contains "$out" "TOTAL                    402" "(a) grand total wrong"
pass "(a) task-id mode sums main + subagents"

# (b) non-claude harness refused
fm_write_meta "$HOME_DIR/state/tok-codex.meta" "worktree=$CWD" "harness=codex" "kind=ship"
out=$("$TOOL" tok-codex 2>&1); code=$?
expect_code 3 "$code" "(b) non-claude harness should exit 3"
assert_contains "$out" "only supported for claude" "(b) should explain claude-only"
pass "(b) non-claude harness refused with exit 3"

# (c) --json emits the machine object
out=$("$TOOL" tok-a --json); code=$?
expect_code 0 "$code" "(c) --json should succeed"
assert_contains "$out" '"total":402' "(c) json total wrong"
assert_contains "$out" '"input":14' "(c) json input wrong"
assert_contains "$out" '"sessions":1' "(c) json sessions wrong"
pass "(c) --json emits machine object"

# (d) default counts newest session only; --all counts every session
mkdir -p "$PROJDIR/sess-old/subagents"
usage_line 1000 2000 3000 4000 > "$PROJDIR/sess-old.jsonl"
touch -t 202001010000 "$PROJDIR/sess-old.jsonl"
touch -t 202601010000 "$PROJDIR/sess-main.jsonl"
out=$("$TOOL" --cwd "$CWD" --json); code=$?
expect_code 0 "$code" "(d) default cwd mode should succeed"
assert_contains "$out" '"total":402' "(d) default should count only newest session (402), not the old one"
out=$("$TOOL" --cwd "$CWD" --all --json); code=$?
expect_code 0 "$code" "(d) --all should succeed"
# --all adds old session: +1000/2000/3000/4000 = +10000 -> 10402
assert_contains "$out" '"total":10402' "(d) --all should sum every session"
assert_contains "$out" '"sessions":2' "(d) --all should report 2 sessions"
pass "(d) newest-session default vs --all"

# (e) --cwd mode without a task/meta already exercised above; confirm --session
out=$("$TOOL" --cwd "$CWD" --session sess-old --json); code=$?
expect_code 0 "$code" "(e) --session should succeed"
assert_contains "$out" '"total":10000' "(e) --session should scope to just that session"
pass "(e) --cwd / --session scoping"

# (f) no transcripts for a cwd -> exit 4
out=$("$TOOL" --cwd "$TMP/wt/nonexistent" 2>&1); code=$?
expect_code 4 "$code" "(f) missing session data should exit 4"
pass "(f) missing session data exits 4"

# (g) guard lines already interleaved in sess-main proved they contribute 0 in (a).
pass "(g) malformed / non-usage lines contribute nothing"

echo "1..7"
