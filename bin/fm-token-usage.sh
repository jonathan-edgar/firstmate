#!/usr/bin/env bash
# fm-token-usage.sh - report claude token usage for a crewmate/scout task.
#
# Why this exists: firstmate supervises crewmates but had no precise accounting of
# what a crewmate cost in tokens. The claude harness pane shows only per-subagent
# counters, not a session total, so eyeballing the pane undercounts. This reads
# claude's own session transcripts, which survive teardown, and sums the exact
# per-message usage.
#
# Data source (claude Code, verified 2026-07-07 on Claude Code 2.1.x):
#   ~/.claude/projects/<encoded-cwd>/<session-id>.jsonl              main agent
#   ~/.claude/projects/<encoded-cwd>/<session-id>/subagents/*.jsonl  each subagent
# The <encoded-cwd> is the absolute worktree path with every '/' and '.'
# replaced by '-'. Subagent (Task) usage lives ONLY in the subagents/ dir, never
# in the main jsonl (its lines carry no isSidechain usage), so both must be
# summed or the total undercounts by the whole subagent fan-out.
# See docs/token-usage.md for the empirical evidence.
#
# Usage:
#   fm-token-usage.sh <task-id> [--json]
#   fm-token-usage.sh --cwd <abs-path> [--session <id>] [--all] [--since <epoch>] [--json]
#
# task-id mode reads worktree= and harness= from state/<id>.meta. Only
# harness=claude is supported; any other harness exits non-zero with a clear
# message, because non-claude adapters record usage differently.
#
# Session scoping (a pooled worktree slot is reused across tasks, so a cwd can
# hold several sessions over time):
#   default      the NEWEST session in the cwd (by main-jsonl mtime) + its subagents
#   --session ID exactly that session + its subagents
#   --since EPOCH every session whose main jsonl mtime >= EPOCH + their subagents
#   --all        every session ever recorded for the cwd + all subagents
# At a crewmate's done (the normal call site) the newest session IS this task's,
# so the default needs no flags.
#
# Env: FM_CLAUDE_PROJECTS_DIR overrides ~/.claude/projects (used by the tests).
#
# Output: a human summary by default, or a JSON object with --json:
#   {"input":N,"output":N,"cache_create":N,"cache_read":N,"total":N,"sessions":N,"files":N}
# Read-only. Exit 0 on a successful read (even zero usage), 2 on a usage error,
# 3 on an unsupported harness, 4 when no session data exists for the cwd.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PROJECTS_DIR="${FM_CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"

usage() {
  echo "usage: fm-token-usage.sh <task-id> [--json]" >&2
  echo "       fm-token-usage.sh --cwd <abs-path> [--session <id>] [--all] [--since <epoch>] [--json]" >&2
}

CWD=""
ID=""
SESSION=""
SINCE=""
ALL=0
JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --cwd) CWD=${2:-}; shift 2 ;;
    --session) SESSION=${2:-}; shift 2 ;;
    --since) SINCE=${2:-}; shift 2 ;;
    --all) ALL=1; shift ;;
    --json) JSON=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "fm-token-usage.sh: unknown option $1" >&2; usage; exit 2 ;;
    *)
      if [ -z "$ID" ]; then ID=$1; else
        echo "fm-token-usage.sh: unexpected argument $1" >&2; usage; exit 2
      fi
      shift ;;
  esac
done

HARNESS="claude"
if [ -n "$ID" ]; then
  META="$STATE/$ID.meta"
  [ -f "$META" ] || { echo "fm-token-usage.sh: no meta for task '$ID' at $META" >&2; exit 2; }
  CWD=$(sed -n 's/^worktree=//p' "$META" | head -1)
  HARNESS=$(sed -n 's/^harness=//p' "$META" | head -1)
  [ -n "$CWD" ] || { echo "fm-token-usage.sh: meta for '$ID' has no worktree=" >&2; exit 2; }
elif [ -z "$CWD" ]; then
  usage; exit 2
fi

case "$HARNESS" in
  claude|claude*) : ;;
  *) echo "fm-token-usage.sh: token usage is only supported for claude crewmates (harness=$HARNESS)" >&2; exit 3 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "fm-token-usage.sh: jq is required" >&2; exit 2; }

# Encode the absolute cwd the way claude names its project dir: every '/' and
# '.' becomes '-'.
enc=$(printf '%s' "$CWD" | tr './' '-')
PROJDIR="$PROJECTS_DIR/$enc"
[ -d "$PROJDIR" ] || { echo "fm-token-usage.sh: no claude session data for $CWD (looked in $PROJDIR)" >&2; exit 4; }

_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }

# Collect the main-session jsonl files that are in scope.
mains=()
if [ -n "$SESSION" ]; then
  [ -f "$PROJDIR/$SESSION.jsonl" ] && mains+=("$PROJDIR/$SESSION.jsonl")
else
  all_mains=()
  while IFS= read -r f; do all_mains+=("$f"); done < <(find "$PROJDIR" -maxdepth 1 -type f -name '*.jsonl' 2>/dev/null | sort)
  if [ "${#all_mains[@]}" -eq 0 ]; then
    echo "fm-token-usage.sh: no session transcripts under $PROJDIR" >&2; exit 4
  fi
  if [ "$ALL" -eq 1 ]; then
    mains=("${all_mains[@]}")
  elif [ -n "$SINCE" ]; then
    for f in "${all_mains[@]}"; do
      m=$(_mtime "$f"); [ -n "$m" ] && [ "$m" -ge "$SINCE" ] && mains+=("$f")
    done
  else
    # newest single session by mtime
    newest=""; newest_m=-1
    for f in "${all_mains[@]}"; do
      m=$(_mtime "$f"); [ -n "$m" ] || continue
      if [ "$m" -gt "$newest_m" ]; then newest_m=$m; newest=$f; fi
    done
    [ -n "$newest" ] && mains+=("$newest")
  fi
fi

[ "${#mains[@]}" -gt 0 ] || { echo "fm-token-usage.sh: no session transcript in scope for $CWD" >&2; exit 4; }

# For every in-scope session, add its subagents/*.jsonl (subagent usage lives
# there, not in the main jsonl).
files=()
for m in "${mains[@]}"; do
  files+=("$m")
  sid=$(basename "$m" .jsonl)
  subdir="$PROJDIR/$sid/subagents"
  if [ -d "$subdir" ]; then
    while IFS= read -r sf; do files+=("$sf"); done < <(find "$subdir" -type f -name '*.jsonl' 2>/dev/null)
  fi
done

# Sum per-message usage across every in-scope file. A malformed or non-message
# line contributes nothing (guarded by `objects`).
read -r I O CC CR < <(
  jq -n -r '
    reduce inputs as $l (
      {i:0,o:0,cc:0,cr:0};
      # `// {}` is load-bearing: a line without a usage object must yield {},
      # not empty. An empty result here would make this reduce step produce no
      # output, which jq treats as resetting the accumulator to null - silently
      # discarding every token counted so far (real transcripts interleave many
      # non-usage lines, so this would zero out the total).
      (($l.message | objects | .usage | objects) // {}) as $u
      | { i:(.i + ($u.input_tokens // 0)),
          o:(.o + ($u.output_tokens // 0)),
          cc:(.cc + ($u.cache_creation_input_tokens // 0)),
          cr:(.cr + ($u.cache_read_input_tokens // 0)) }
    ) | "\(.i) \(.o) \(.cc) \(.cr)"
  ' "${files[@]}"
)
TOTAL=$((I + O + CC + CR))
NSESS=${#mains[@]}
NFILES=${#files[@]}

if [ "$JSON" -eq 1 ]; then
  printf '{"input":%d,"output":%d,"cache_create":%d,"cache_read":%d,"total":%d,"sessions":%d,"files":%d}\n' \
    "$I" "$O" "$CC" "$CR" "$TOTAL" "$NSESS" "$NFILES"
else
  label=${ID:-$CWD}
  printf 'token usage for %s (claude):\n' "$label"
  printf '  input           %12d\n' "$I"
  printf '  output          %12d\n' "$O"
  printf '  cache-create    %12d\n' "$CC"
  printf '  cache-read      %12d\n' "$CR"
  printf '  TOTAL           %12d  (%d session(s), %d transcript file(s))\n' "$TOTAL" "$NSESS" "$NFILES"
fi
