#!/usr/bin/env bash
# Regression tests for the pinned shared no-mistakes gate action.
#
# The ref is read out of .github/workflows/no-mistakes-required.yml rather than
# repeated here, so these tests always exercise the verifier the required check
# actually runs. A second copy of the pin drifts silently: rolling the workflow
# to v1.80.1 left this script fetching the previous action, so the tests kept
# passing against a verifier no PR was ever graded by.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GATE_WORKFLOW="$ROOT/.github/workflows/no-mistakes-required.yml"
TMP_ROOT=$(fm_test_tmproot fm-no-mistakes-required)
VERIFY="$TMP_ROOT/verify.py"
OLD_SHA=1111111111111111111111111111111111111111
NEW_SHA=2222222222222222222222222222222222222222
SIGNATURE='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'
COMPLETED_STEPS='[{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"document","status":"completed"}]'

# Echo the immutable ref the required check is pinned to, resolved from the
# workflow's parsed step list rather than from how the file happens to be typed.
resolve_pinned_action_ref() {
  ruby -ryaml -e '
doc = YAML.load_file(ARGV[0])
uses = doc.fetch("jobs").values.flat_map { |job| job.fetch("steps", []) }
          .map { |step| step["uses"] }.compact
          .select { |u| u.start_with?("kunchenguid/no-mistakes/.github/actions/require-no-mistakes@") }
abort "expected exactly one require-no-mistakes step, found #{uses.length}" unless uses.length == 1
ref = uses.first.split("@", 2).last
abort "require-no-mistakes must be pinned to a full commit SHA, got #{ref}" unless ref =~ /\A[0-9a-f]{40}\z/
puts ref
' "$GATE_WORKFLOW"
}

fetch_shared_verifier() {
  command -v curl >/dev/null 2>&1 || fail "curl is required to exercise the pinned shared action"
  command -v python3 >/dev/null 2>&1 || fail "python3 is required to exercise the pinned shared action"
  command -v ruby >/dev/null 2>&1 || fail "ruby is required to parse the required-check workflow as YAML"
  assert_present "$GATE_WORKFLOW" ".github/workflows/no-mistakes-required.yml is missing"
  ACTION_REF=$(resolve_pinned_action_ref) \
    || fail "could not resolve the pinned require-no-mistakes action ref"
  curl --fail --silent --show-error --location \
    "https://raw.githubusercontent.com/kunchenguid/no-mistakes/${ACTION_REF}/.github/actions/require-no-mistakes/verify.py" \
    > "$VERIFY" || fail "could not fetch the pinned shared action verifier"
  [ -s "$VERIFY" ] || fail "the pinned shared action verifier was empty"
}

run_verifier() {
  local body=$1 head=$2
  PR_BODY="$body" PR_HEAD_SHA="$head" PR_AUTHOR=regression PR_NUMBER=3006 \
    python3 "$VERIFY" 2>&1
}

test_matching_head_and_completed_steps_pass() {
  local body output rc
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"head_sha\":\"$NEW_SHA\",\"steps\":$COMPLETED_STEPS} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  expect_code 0 "$rc" "shared action rejected an attestation bound to the current PR head"
  assert_contains "$output" "Found structurally compliant pipeline step attestation." \
    "shared action did not report the matching attestation as compliant"
  pass "shared action accepts a matching head_sha with completed required steps"
}

test_mismatched_head_fails_with_both_shas() {
  local body output rc
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"head_sha\":\"$OLD_SHA\",\"steps\":$COMPLETED_STEPS} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  [ "$rc" -ne 0 ] || fail "shared action accepted an attestation from a different PR head"
  assert_contains "$output" "$OLD_SHA" \
    "mismatched-head failure did not name the attestation head SHA"
  assert_contains "$output" "$NEW_SHA" \
    "mismatched-head failure did not name the actual PR head SHA"
  pass "shared action rejects a mismatched head_sha and names both SHAs"
}

test_missing_head_fails() {
  local body output rc
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"steps\":$COMPLETED_STEPS} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  [ "$rc" -ne 0 ] || fail "shared action accepted an attestation without head_sha"
  assert_contains "$output" "structured pipeline step attestation" \
    "missing-head failure did not explain that the attestation is invalid"
  pass "shared action rejects an attestation with no head_sha"
}

fetch_shared_verifier
test_matching_head_and_completed_steps_pass
test_mismatched_head_fails_with_both_shas
test_missing_head_fails
