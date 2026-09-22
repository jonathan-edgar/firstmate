#!/usr/bin/env bash
# Behavior tests for the worktree-tangle guards.
#
# Firstmate is a treehouse-pooled git repo of itself: linked worktrees and
# secondmate homes all sit at a detached HEAD on the default branch, while the
# PRIMARY checkout (FM_ROOT) is a normal checkout on a real branch. The "tangle"
# is a crewmate branching/committing in the primary instead of its own worktree,
# stranding the primary on a feature branch. Two guards cover it:
#   GUARD 1 (prevention) - the brief asserts isolation before its branch step, and
#            fm-spawn refuses to launch unless the resolved worktree is isolated
#            AND a worktree of the project being spawned into.
#   GUARD 2 (detection)  - fm-guard and fm-bootstrap alarm when the primary is on
#            a feature branch, and stay silent on the default branch or detached.
# These cases pin: the shared lib's branch classification, the fm-guard banner,
# the fm-bootstrap problem line, the brief assertion ordering, the fm-spawn
# abort, and the worktree-discovery poll's refusal to latch onto an unrelated
# git repo - all hermetic over temp git repos and fakebins.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-tangle-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-tangle-guard)
fm_git_identity fmtest fmtest@example.invalid

# A fresh git repo on `main` with one commit and a local origin. Echoes its path.
make_repo() {
  local dir=$1
  git init -q -b main "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  fm_git_add_origin "$dir" "$dir.origin.git"
  printf '%s\n' "$dir"
}

# --- shared lib: branch classification --------------------------------------

# fm_primary_tangle_branch is the whole scoping decision: a NAMED non-default
# branch is the tangle; the default branch and detached HEAD are healthy.
test_lib_classification() {
  local repo n=0 label state branch expect out
  repo=$(make_repo "$TMP_ROOT/lib-repo")
  while IFS='|' read -r label state branch expect; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case "$state" in
      default)  git -C "$repo" checkout -q main ;;
      feature)  git -C "$repo" checkout -q -B "$branch" ;;
      detached) git -C "$repo" checkout -q main; git -C "$repo" checkout -q --detach ;;
    esac
    out=$(fm_primary_tangle_branch "$repo" || true)
    [ "$out" = "$expect" ] || fail "$label: expected tangle='$expect', got '$out'"
  done <<'ROWS'
on the default branch is healthy|default||
on a feature branch is the tangle|feature|fm/readme-restructure-d3|fm/readme-restructure-d3
detached HEAD on default is healthy (worktrees, secondmate homes)|detached||
ROWS
  # A non-git directory is not a tangle and must not error.
  out=$(fm_primary_tangle_branch "$TMP_ROOT" || true)
  [ -z "$out" ] || fail "non-git dir wrongly reported a tangle: '$out'"
  pass "fm_primary_tangle_branch: feature branch alarms; default/detached/non-git stay silent"
}

# --- GUARD 2a: fm-guard banner ----------------------------------------------

run_guard() {
  # Scope the guard to a temp repo as the primary checkout; state lives under it.
  FM_ROOT_OVERRIDE="$1" FM_HOME="$1" "$ROOT/bin/fm-guard.sh" 2>&1
}

test_guard_banner() {
  local repo out
  repo=$(make_repo "$TMP_ROOT/guard-repo")

  out=$(run_guard "$repo")
  assert_not_contains "$out" "WORKTREE TANGLE" "guard alarmed while primary was on main"

  git -C "$repo" checkout -q --detach
  out=$(run_guard "$repo")
  assert_not_contains "$out" "WORKTREE TANGLE" "guard alarmed on a detached HEAD (legitimate worktree state)"

  git -C "$repo" checkout -q -B fm/tangle-aa1
  out=$(run_guard "$repo")
  assert_contains "$out" "WORKTREE TANGLE" "guard did not alarm on a feature branch in the primary"
  assert_contains "$out" "fm/tangle-aa1" "guard banner did not name the offending branch"
  assert_contains "$out" "checkout main" "guard banner did not print the restore remediation"
  out=$(FM_GUARD_READ_ONLY=1 run_guard "$repo")
  assert_contains "$out" "WORKTREE TANGLE" "read-only guard did not keep the tangle alarm"
  assert_contains "$out" "read-only session must leave restore work" "read-only guard did not explain restore ownership"
  assert_not_contains "$out" "checkout main" "read-only guard printed a state-changing restore command"
  pass "fm-guard: bordered tangle banner fires only for a feature branch and suppresses repair commands in read-only mode"
}

# --- GUARD 2b: fm-bootstrap problem line ------------------------------------

run_bootstrap() {
  # No projects/ under the home keeps fleet sync inert; grep isolates the line.
  FM_ROOT_OVERRIDE="$1" FM_HOME="$1" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null
}

test_bootstrap_line() {
  local repo out
  repo=$(make_repo "$TMP_ROOT/bootstrap-repo")

  out=$(run_bootstrap "$repo" | grep '^TANGLE:' || true)
  [ -z "$out" ] || fail "bootstrap emitted a TANGLE line while on main: $out"

  git -C "$repo" checkout -q --detach
  out=$(run_bootstrap "$repo" | grep '^TANGLE:' || true)
  [ -z "$out" ] || fail "bootstrap emitted a TANGLE line on a detached HEAD: $out"

  git -C "$repo" checkout -q -B fm/tangle-bb2
  out=$(run_bootstrap "$repo" | grep '^TANGLE:' || true)
  assert_contains "$out" "fm/tangle-bb2" "bootstrap did not report the tangled branch"
  assert_contains "$out" "checkout main" "bootstrap TANGLE line lacked the restore remediation"
  out=$(FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" FM_BOOTSTRAP_DETECT_ONLY=1 "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null | grep '^TANGLE:' || true)
  assert_contains "$out" "fm/tangle-bb2" "detect-only bootstrap did not report the tangled branch"
  assert_contains "$out" "read-only session must leave restore work" "detect-only bootstrap did not explain restore ownership"
  assert_not_contains "$out" "checkout main" "detect-only bootstrap printed a state-changing restore command"
  pass "fm-bootstrap: TANGLE problem line fires only for a feature branch and suppresses repair commands in detect-only mode"
}

# --- GUARD 1a: brief isolation assertion ------------------------------------

# The generated ship brief must carry the isolation assertion AHEAD of the
# `git checkout -b` step, so the crewmate verifies its worktree before branching.
test_brief_assertion_precedes_branch() {
  local home brief iso br
  home="$TMP_ROOT/brief-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" tangle-brief-cc3 alpha --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/tangle-brief-cc3/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  # shellcheck disable=SC2016 # The generated instruction keeps the stamp literal.
  assert_grep 'blocked [at=<epoch>]: launched in primary checkout, not an isolated worktree' "$brief" \
    "brief is missing the isolation blocked-status contract"
  assert_grep "The path check is authoritative" "$brief" \
    "brief must make the path check authoritative"
  assert_no_grep "A reliable test that you are in a linked worktree" "$brief" \
    "brief must not present git-dir/common-dir as decisive"
  assert_no_grep "they are identical in the primary checkout" "$brief" \
    "brief must not claim the primary checkout has identical git dirs"
  iso=$(grep -n 'launched in primary checkout, not an isolated worktree' "$brief" | head -1 | cut -d: -f1)
  br=$(grep -n 'git checkout -b fm/' "$brief" | head -1 | cut -d: -f1)
  if [ -z "$iso" ] || [ -z "$br" ]; then
    fail "brief missing assertion ($iso) or branch step ($br)"
  fi
  [ "$iso" -lt "$br" ] || fail "isolation assertion (line $iso) must precede the branch step (line $br)"
  pass "fm-brief: ship brief asserts worktree isolation before the branch step"
}

# --- GUARD 1b: fm-spawn isolation abort -------------------------------------

# Spawn isolation uses the shared spawn fakebin (pane path + window ops).
run_spawn() {
  local home=$1 id=$2 proj=$3 pane=$4 fakebin=$5
  fm_test_spawn_brief "$home" "$id" brief
  fm_test_run_spawn "$home" "$pane" "$fakebin" \
    "$id" "$proj" codex --mode no-mistakes --yolo off
}

# A sequence-driven variant of the shared spawn fakebin: FM_FAKE_PANE_PATH_SEQ
# names a file of one pane cwd per line, consumed one per poll, with the last
# line repeating forever after. That is what reproduces the real shape of the
# oh-my-zsh bug, where the pane sits somewhere else for the first polls and only
# then lands in the task worktree. Everything else matches the shared stub.
make_spawn_seq_fakebin() {
  local dir=$1 fakebin
  fakebin=$(make_spawn_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    if [ -n "${FM_FAKE_PANE_PATH_SEQ:-}" ]; then
      # One line per poll. A sibling .n file carries the cursor across the
      # separate fake-tmux processes the poll loop spawns.
      n_file="$FM_FAKE_PANE_PATH_SEQ.n"
      n=$(cat "$n_file" 2>/dev/null || echo 1)
      total=$(wc -l < "$FM_FAKE_PANE_PATH_SEQ")
      [ "$n" -le "$total" ] || n=$total
      sed -n "${n}p" "$FM_FAKE_PANE_PATH_SEQ"
      echo $((n + 1)) > "$n_file"
      exit 0
    fi
    printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|set-window-option|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

# run_spawn_seq <home> <id> <proj> <seq-file> <fakebin>
# Same as run_spawn, but the pane reports one path per poll from <seq-file>.
# FM_SPAWN_WORKTREE_TIMEOUT bounds the poll so a sequence that never settles
# fails in a few polls instead of the 60-poll production bound.
run_spawn_seq() {
  local home=$1 id=$2 proj=$3 seq=$4 fakebin=$5
  fm_test_spawn_brief "$home" "$id" brief
  rm -f "$seq.n"
  FM_FAKE_PANE_PATH_SEQ="$seq" FM_SPAWN_WORKTREE_TIMEOUT="${FM_TEST_SPAWN_TIMEOUT:-8}" \
    fm_test_run_spawn "$home" '' "$fakebin" \
    "$id" "$proj" codex --mode no-mistakes --yolo off
}

test_spawn_isolation_abort() {
  local home proj fakebin out status
  home="$TMP_ROOT/spawn-home"
  mkdir -p "$home/data"
  proj=$(make_repo "$TMP_ROOT/spawn-proj")
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/spawn-fake")
  # The assertions concern identity, not how long an unchanged cwd is polled.
  fm_test_fake_sleep_noop "$fakebin"
  # A genuine isolated linked worktree of the project, detached on the default.
  git -C "$proj" worktree add -q --detach "$TMP_ROOT/spawn-wt" >/dev/null 2>&1
  # The non-git case must BE non-git wherever this suite runs. A directory under
  # TMPDIR is not one when TMPDIR itself sits inside a git repository - git walks
  # up and finds that repo, and the spawn reports the subdirectory cause instead.
  # GIT_CEILING_DIRECTORIES stops that upward walk: git does not chdir up into a
  # listed directory, though it never excludes the directory being searched, so
  # the ceiling is the PARENT of the path handed to the spawn (git(1),
  # "GIT_CEILING_DIRECTORIES").
  mkdir -p "$TMP_ROOT/spawn-notgit-root/plain" "$proj/sub"

  # Abort: the pane resolves to a plain non-git directory (not a worktree at all).
  # The discovery poll screens every candidate with the isolation conditions, so
  # a path like this is never adopted and the refusal comes from the poll's own
  # deadline, naming the path and why it was rejected. The assertions pin which
  # cause fired, not the operator wording that explains it.
  out=$(GIT_CEILING_DIRECTORIES="$TMP_ROOT/spawn-notgit-root" \
    run_spawn "$home" abort-notgit-dd4 "$proj" "$TMP_ROOT/spawn-notgit-root/plain" "$fakebin"); status=$?
  expect_code 1 "$status" "spawn into a non-worktree dir should abort"
  assert_contains "$out" "did not enter an isolated worktree" "non-worktree spawn lacked the isolation error"
  assert_contains "$out" "not inside a git worktree" "non-worktree spawn did not say why the path was rejected"
  assert_absent "$home/state/abort-notgit-dd4.meta" "aborted spawn must not record meta"

  # Abort: the pane resolves INTO the primary checkout (a subdir of PROJ_ABS).
  # This one DOES share the project's git dir, so the poll accepts it and the
  # isolation rule is what refuses it - the two checks are independent.
  out=$(run_spawn "$home" abort-primary-ee5 "$proj" "$proj/sub" "$fakebin"); status=$?
  expect_code 1 "$status" "spawn landing inside the primary checkout should abort"
  assert_contains "$out" "did not enter an isolated worktree" "primary-checkout spawn lacked the isolation error"
  assert_contains "$out" "not a worktree root" "primary-checkout spawn did not say why the path was rejected"
  assert_absent "$home/state/abort-primary-ee5.meta" "aborted spawn must not record meta"

  # Proceed: the pane resolves to a genuine, isolated worktree.
  out=$(run_spawn "$home" ok-isolated-ff6 "$proj" "$TMP_ROOT/spawn-wt" "$fakebin"); status=$?
  expect_code 0 "$status" "spawn into a genuine isolated worktree should succeed"
  assert_contains "$out" "spawned ok-isolated-ff6" "isolated spawn did not report success"
  assert_not_contains "$out" "isolated worktree" "isolated spawn wrongly tripped the guard"
  pass "fm-spawn: aborts unless the resolved worktree is a genuine, isolated worktree"
}

# --- GUARD 1c: fm-spawn tmux window construction ----------------------------

# The prevention guard also depends on fm-spawn building robust tmux commands
# under a non-default tmux config (base-index 1, automatic-rename on). A RECORDING
# fake tmux logs every invocation and returns a sentinel window id, so these
# assertions pin the command construction deterministically, with no live tmux:
#   - window creation targets the session with a trailing colon (append form), so
#     tmux appends at the next free index instead of the active window index, which
#     collides under base-index 1;
#   - the window id is captured (-P -F #{window_id}) and automatic-rename/allow-rename
#     are disabled so the fm-<id> name survives treehouse cd'ing into the worktree;
#   - the treehouse-get send-keys and the worktree wait loop target that stable
#     window id, never the (possibly-renamed) name - a lost name would let
#     display-message fall back to the active client's window and misread firstmate's
#     OWN pane as the worktree, tangling a hook into the primary checkout.
make_spawn_record_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
[ -n "${FM_TMUX_REC:-}" ] && printf 'tmux %s\n' "$*" >> "$FM_TMUX_REC"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  new-window) printf '%s\n' "@spawnwid"; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|send-keys|set-window-option) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

run_spawn_record() {
  local home=$1 id=$2 proj=$3 pane=$4 fakebin=$5 rec=$6
  fm_test_spawn_brief "$home" "$id" brief
  FM_TMUX_REC="$rec" \
    fm_test_run_spawn "$home" "$pane" "$fakebin" \
    "$id" "$proj" codex --mode no-mistakes --yolo off
}

test_spawn_tmux_window_construction() {
  local home proj fakebin rec wt out status
  home="$TMP_ROOT/spawn-rec-home"
  mkdir -p "$home/data"
  proj=$(make_repo "$TMP_ROOT/spawn-rec-proj")
  fakebin=$(make_spawn_record_fakebin "$TMP_ROOT/spawn-rec-fake")
  rec="$TMP_ROOT/spawn-rec.log"
  : > "$rec"
  wt="$TMP_ROOT/spawn-rec-wt"
  git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1

  out=$(run_spawn_record "$home" rec-win-gg7 "$proj" "$wt" "$fakebin" "$rec"); status=$?
  expect_code 0 "$status" "spawn into a genuine worktree should succeed"
  assert_contains "$out" "spawned rec-win-gg7" "recording spawn did not report success"

  # Bug 1 fix: append-form window creation (trailing colon on the session target).
  assert_grep "new-window -dP -F #{window_id} -t firstmate: -n fm-rec-win-gg7" "$rec" \
    "new-window must append at the session (trailing colon) and capture the window id"
  assert_no_grep "new-window -dP -F #{window_id} -t firstmate -n" "$rec" \
    "new-window must not target the bare session name (collides under base-index 1)"

  # Bug 2 fix (a): pin the window name against automatic-rename / allow-rename.
  assert_grep "set-window-option -t @spawnwid automatic-rename off" "$rec" \
    "must disable automatic-rename on the spawned window"
  assert_grep "set-window-option -t @spawnwid allow-rename off" "$rec" \
    "must disable allow-rename on the spawned window"

  # Bug 2 fix (b): treehouse-get and the worktree wait loop target the stable id.
  assert_grep "send-keys -t @spawnwid treehouse get Enter" "$rec" \
    "treehouse get must be sent to the stable window id"
  assert_grep "display-message -p -t @spawnwid #{pane_current_path}" "$rec" \
    "the worktree wait loop must query the stable window id, not the name"

  pass "fm-spawn: appends windows by session-colon, pins the name, and targets the window id"
}

# --- GUARD 1d: the discovery poll must not latch onto a foreign repo --------

# Regression for the oh-my-zsh spawn incident. oh-my-zsh.sh runs
# `builtin cd -q "$ZSH"` on EVERY shell startup to stamp the zcompdump
# revision, so a freshly spawned pane transiently reports ~/.oh-my-zsh as its
# foreground cwd. The poll used to accept the first path that merely DIFFERED
# from the project, and the isolation rule used to ask only "a git repo whose
# root is itself, and not the primary" - which ~/.oh-my-zsh satisfies. Five
# agents launched in the user's shell framework directory before it was
# diagnosed. The property that actually identifies a task worktree is a shared
# --git-common-dir with the project, so the standing behaviour is: a foreign
# repo is never accepted, and the poll keeps waiting for the real worktree.
test_spawn_rejects_foreign_repo_cwd() {
  local home proj fakebin foreign wt seq out status
  home="$TMP_ROOT/foreign-home"
  mkdir -p "$home/data"
  proj=$(make_repo "$TMP_ROOT/foreign-proj")
  fakebin=$(make_spawn_seq_fakebin "$TMP_ROOT/foreign-fake")
  # The assertions concern identity, not how long an unchanged cwd is polled.
  fm_test_fake_sleep_noop "$fakebin"
  # Stands in for ~/.oh-my-zsh: a real git repo, its own root, not the primary.
  foreign=$(make_repo "$TMP_ROOT/foreign-omz")
  wt="$TMP_ROOT/foreign-wt"
  git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1

  # Never launch into a git repo that is not this project's, however long it
  # sits there. Without the common-dir check this spawn SUCCEEDS into $foreign.
  out=$(run_spawn "$home" abort-foreign-gg7 "$proj" "$foreign" "$fakebin"); status=$?
  expect_code 1 "$status" "spawn into an unrelated git repo should abort"
  assert_contains "$out" "did not enter an isolated worktree" "foreign-repo spawn lacked the resolution error"
  assert_contains "$out" "NOT a worktree of the spawning project" "foreign-repo spawn did not say why the path was rejected"
  assert_contains "$out" "$foreign" "error should name the impostor path that was seen"
  assert_absent "$home/state/abort-foreign-gg7.meta" "aborted spawn must not record meta"

  # The live shape: the pane sits in the foreign repo for the first polls, then
  # treehouse lands it in the real worktree. The poll must wait that out and
  # resolve the worktree, not latch onto the first different path it saw. The
  # last line repeats, which also satisfies the poll's two-consecutive-reads rule.
  seq="$TMP_ROOT/foreign-seq"
  printf '%s\n%s\n%s\n' "$foreign" "$foreign" "$wt" > "$seq"
  out=$(run_spawn_seq "$home" ok-waited-hh8 "$proj" "$seq" "$fakebin"); status=$?
  expect_code 0 "$status" "spawn should succeed once the pane reaches the real worktree"
  assert_present "$home/state/ok-waited-hh8.meta" "successful spawn must record meta"
  assert_grep "worktree=$wt" "$home/state/ok-waited-hh8.meta" \
    "spawn resolved the wrong worktree; it must wait past the impostor cwd"
  assert_no_grep "worktree=$foreign" "$home/state/ok-waited-hh8.meta" \
    "spawn latched onto the impostor repo instead of the task worktree"
  pass "fm-spawn: the worktree poll waits past an unrelated git repo instead of launching in it"
}

# --- GUARD 1e: the fail-open branch -----------------------------------------

# The identity predicate deliberately fails OPEN: when the project's own
# --git-common-dir cannot be resolved it never blocks a spawn by itself, and
# the operator is told on stderr that the check is off. On this base the
# isolation guard's own unresolved-git-dir rule (spawn_worktree_isolated) then
# refuses every candidate, genuine worktree or not, so the spawn does not
# launch; that refusal is the isolation guard's, not the identity check's.
# Both halves of the identity contract are pinned here: the warning fires, and
# the reason reported is never the identity predicate's.
test_spawn_fail_open_when_common_dir_unknown() {
  local home proj fakebin foreign real_git out status
  home="$TMP_ROOT/failopen-home"
  mkdir -p "$home/data"
  proj=$(make_repo "$TMP_ROOT/failopen-proj")
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/failopen-fake")
  fm_test_fake_sleep_noop "$fakebin"
  foreign=$(make_repo "$TMP_ROOT/failopen-omz")
  real_git=$(command -v git)

  # Shadow git so only `rev-parse --path-format=...` fails, exactly as a git
  # older than 2.31 would; every other invocation passes through to real git.
  cat > "$fakebin/git" <<SH
#!/usr/bin/env bash
set -u
for arg in "\$@"; do
  case "\$arg" in
    --path-format=*) printf 'error: unknown option \`%s'"'"'\n' "\$arg" >&2; exit 129 ;;
  esac
done
exec "$real_git" "\$@"
SH
  chmod +x "$fakebin/git"

  out=$(run_spawn "$home" failopen-jj9 "$proj" "$foreign" "$fakebin"); status=$?
  assert_contains "$out" "worktree-identity check is DISABLED" \
    "fail-open spawn did not warn that the identity check is off"
  assert_not_contains "$out" "NOT a worktree of the spawning project" \
    "the identity predicate must not block when the project's common dir is unknown"
  expect_code 1 "$status" "the isolation guard's own unresolved-git-dir rule still refuses the spawn"
  assert_contains "$out" "its git directory could not be resolved" \
    "the refusal must come from the isolation guard's unresolved-git-dir rule"
  assert_absent "$home/state/failopen-jj9.meta" "refused spawn must not record meta"
  pass "fm-spawn: an unresolvable project git common dir disables the identity check loudly and never blocks by itself"
}

test_lib_classification
test_guard_banner
test_bootstrap_line
test_brief_assertion_precedes_branch
test_spawn_isolation_abort
test_spawn_tmux_window_construction
test_spawn_rejects_foreign_repo_cwd
test_spawn_fail_open_when_common_dir_unknown
