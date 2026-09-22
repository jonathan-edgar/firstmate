# Crewmate token accounting (`bin/fm-token-usage.sh`)

Precise per-crewmate token usage for `claude`-harness crewmates and scouts, read
from claude's own session transcripts.
The claude pane shows only per-subagent counters, never a session total, so
reading it undercounts; the transcripts are authoritative and survive teardown.

## Data source (verified 2026-07-07, Claude Code 2.1.x)

Claude Code writes one directory per working directory under
`~/.claude/projects/`, named by replacing every `/` and `.` in the absolute cwd
with `-`.
For example the worktree `/Users/me/.treehouse/repo-abc/1/repo` becomes
`-Users-me--treehouse-repo-abc-1-repo`.

Inside that directory:

```
<session-id>.jsonl                    the main agent's transcript
<session-id>/subagents/agent-*.jsonl  one transcript per Task subagent
<session-id>/tool-results/            large tool outputs (no usage data)
```

Each assistant message line carries `.message.usage` with `input_tokens`,
`output_tokens`, `cache_creation_input_tokens`, and `cache_read_input_tokens`.
Non-assistant lines (user turns, summaries, string-valued `message`) carry no
usage and contribute nothing.

**Subagent usage lives only in `subagents/`.**
The main jsonl's lines do NOT carry the subagents' usage (no `isSidechain`
usage rows appear there), so a sum of only the main transcript undercounts by the
entire subagent fan-out.
`fm-token-usage.sh` sums the main transcript plus every `subagents/*.jsonl` for
each in-scope session.

## Evidence

Three crewmates run on 2026-07-07 (discogs-rn-app MAPP tickets), each dispatching
6-7 subagents, summed by the tool (`--all`) and cross-checked against an
independent Python parse of the same files:

| Task | files | input | output | cache-create | cache-read | total |
| --- | --- | --- | --- | --- | --- | --- |
| MAPP-3307 | 1 main + 7 sub | 64,927 | 204,768 | 1,271,817 | 17,172,801 | 18,714,313 |
| MAPP-3315 | 1 main + 6 sub | 74,322 | 253,939 | 1,266,306 | 28,667,638 | 30,262,205 |
| MAPP-3329 | 1 main + 6 sub | 134,292 | 230,444 | 2,823,366 | 39,496,130 | 42,684,232 |

Summing only the main transcript (the pre-`subagents/` bug) reported 34,801 for
MAPP-3307 instead of 18,714,313; the regression test
`tests/fm-token-usage.test.sh` interleaves non-usage lines between usage lines to
pin the jq accumulator against silently resetting on them.

## Session scoping

A treehouse pool slot is reused across tasks, so one cwd can accumulate several
sessions over time.
The tool scopes by:

- default: the newest session (by main-jsonl mtime) plus its subagents - correct
  at a crewmate's done, when the newest session is that task's;
- `--session <id>`: exactly that session;
- `--since <epoch>`: every session whose main jsonl is at/after the epoch;
- `--all`: every session recorded for the cwd.

## Usage

```
fm-token-usage.sh <task-id> [--json]                 # reads worktree=/harness= from state/<id>.meta
fm-token-usage.sh --cwd <abs-path> [--all|--since E|--session ID] [--json]
```

Only `harness=claude` is supported; other adapters record usage differently and
exit 3.
`FM_CLAUDE_PROJECTS_DIR` overrides `~/.claude/projects` (used by the tests).
