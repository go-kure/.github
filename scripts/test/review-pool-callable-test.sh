#!/usr/bin/env bash
# review-pool-callable-test.sh — the acceptance workflow can be called by another workflow, and the
# call does not serialize pull requests or collide with its own rerun.
#
# The pr-review workflow runs the acceptance workflow as its review producer. Three properties of
# the workflow decide whether that works, and each is quiet when wrong:
#
# 1. The concurrency group. A hand dispatch serializes on the repository. A call from a pull
#    request run must not, or one slow review holds every other pull request's review. The test for
#    a call reads github.workflow_ref and never github.event_name: in a call the event is the
#    caller's, so a caller started by workflow_dispatch would fall back to the repository-wide group.
# 2. The artifact name. It carries the run attempt, so a rerun does not collide with its first
#    attempt, and the name is the `artifact` output the caller downloads by.
# 3. The inputs. A call takes the same four inputs as a dispatch, because the step bodies the other
#    suites read use `inputs.backend` and the rest, and they read the same names in both modes.
#
# The group is an expression, and this suite reads its text and does not evaluate it. So it pins the
# two things that make the text right: it names the run id, and it puts the non-empty value on the
# true side of `&&`. An empty string on that side is falsy, so `cond && '' || x` always yields x and
# a hand dispatch would lose its repository-wide group.
#
# Every rule has a mutant of the workflow that must fail for that rule. Without it a rule that never
# fires reads as a rule that passes.
#
# Usage: review-pool-callable-test.sh [REPO_ROOT]
# Exit:  0 every case passed; 1 a case failed; 2 the workflow could not be read.
# Needs: yq v4, bash, sed.

# shellcheck disable=SC2016 # the ${{ }} below is workflow expression text compared as a string, never a shell expansion
set -uo pipefail

ROOT="${1:-.}"
WF="$ROOT/.github/workflows/review-pool-acceptance.yml"

if [ ! -f "$WF" ]; then
  echo "cannot read the acceptance workflow at $WF" >&2
  exit 2
fi

PASS=0
FAIL=0
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# q FILE EXPR: one yq read. A failed read is a read that proves nothing. It runs inside a command
# substitution, where an exit would end only the substitution, so it returns 2 and every caller
# passes that on with `|| return 2`; expect() then ends the suite.
q() {
  local out
  if ! out=$(yq -o=json -I0 "$2" "$1"); then
    echo "yq failed to read $1" >&2
    return 2
  fi
  printf '%s' "$out"
}

# violations FILE: one line per rule the workflow breaks. Nothing printed means every rule holds.
# Returns 2 when a read failed.
violations() {
  local f="$1" a b group artifact_env upload job_out wf_out secrets
  a=$(q "$f" '.on.workflow_call.inputs | to_entries | map({"k": .key, "t": .value.type, "r": .value.required, "d": .value.default})') || return 2
  b=$(q "$f" '.on.workflow_dispatch.inputs | to_entries | map({"k": .key, "t": .value.type, "r": .value.required, "d": .value.default})') || return 2
  [ "$a" != null ] && [ "$a" = "$b" ] || echo "inputs: a call must take the same four inputs as a dispatch"

  group=$(q "$f" '.concurrency.group') || return 2
  case "$group" in *github.run_id*) ;; *) echo "group: a call must carry the run id" ;; esac
  case "$group" in
    *"!contains(github.workflow_ref, '/review-pool-acceptance.yml@') && format("*) ;;
    *) echo "group: the non-empty value must sit on the true side of &&" ;;
  esac
  case "$group" in
    *github.event_name*) echo "group: the test must not read github.event_name, the caller's event in a call" ;;
  esac

  artifact_env=$(q "$f" '.jobs.review.env.ARTIFACT_NAME') || return 2
  case "$artifact_env" in
    *github.run_id*github.run_attempt*) ;;
    *) echo "artifact: the name must carry the run id and the run attempt" ;;
  esac
  upload=$(q "$f" '.jobs.review.steps[] | select(.uses != null and (.uses | test("upload-artifact"))) | .with.name') || return 2
  [ "$upload" = '"${{ env.ARTIFACT_NAME }}"' ] || echo "artifact: the upload must use the one defined name"
  job_out=$(q "$f" '.jobs.review.outputs.artifact') || return 2
  [ "$job_out" = '"${{ env.ARTIFACT_NAME }}"' ] || echo "artifact: the job output must be the defined name"
  wf_out=$(q "$f" '.on.workflow_call.outputs.artifact.value') || return 2
  [ "$wf_out" = '"${{ jobs.review.outputs.artifact }}"' ] || echo "artifact: the workflow output must expose the job output"

  secrets=$(q "$f" '.on.workflow_call.secrets | keys | sort | join(",")') || return 2
  [ "$secrets" = '"ANTHROPIC_API_KEY,CLAUDE_CODE_OAUTH_TOKEN,OPENAI_API_KEY"' ] \
    || echo "secrets: a call must declare the three backend credentials"

  # The anonymous registry read never succeeded, so the record carried a field that was always
  # "unavailable". The bundle record is the one identity. A read of the registry, or a field for its
  # digest, is not allowed back.
  if grep -qE 'registry_latest_digest|REGISTRY_LATEST_DIGEST|ghcr\.io/(token|v2)' "$f"; then
    echo "identity: the record must not read the registry or carry a registry digest field"
  fi
}

# expect LABEL WANT FILE: WANT is empty for a workflow that must pass, else text one violation line
# must contain.
expect() {
  local label="$1" want="$2" f="$3" out
  out=$(violations "$f") || { echo "a read failed for $label" >&2; exit 2; }
  if { [ -z "$want" ] && [ -z "$out" ]; } || { [ -n "$want" ] && grep -qF -- "$want" <<<"$out"; }; then
    PASS=$((PASS + 1))
    printf 'PASS  %s\n' "$label"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL  %s: want [%s], got [%s]\n' "$label" "$want" "$out"
  fi
}

# mutant NAME SED_EXPR: a copy of the workflow with one edit. The edit must change the file, or the
# case would pass on an unchanged copy.
mutant() {
  local name="$1" expr="$2"
  sed "$expr" "$WF" > "$WORK/$name.yml"
  if cmp -s "$WF" "$WORK/$name.yml"; then
    echo "mutant $name changed nothing, so its case proves nothing" >&2
    exit 2
  fi
}

expect 'the workflow as it stands breaks no rule' '' "$WF"

mutant repo-only-group \
  "s|&& format('-{0}', github.run_id) \|\| '' }}\$|\&\& '' \|\| format('-{0}', github.run_id) }}|"
expect 'a group with the falsy empty string on the true side is refused' \
  'the non-empty value must sit on the true side' "$WORK/repo-only-group.yml"

mutant group-reads-event-name "s|!contains(github.workflow_ref,|github.event_name != 'workflow_dispatch' \&\& contains(github.workflow_ref,|"
expect 'a group that reads the caller event is refused' \
  'must not read github.event_name' "$WORK/group-reads-event-name.yml"

mutant group-without-run-id "s|format('-{0}', github.run_id)|'-fixed'|"
expect 'a group that no longer carries the run id is refused' \
  'a call must carry the run id' "$WORK/group-without-run-id.yml"

mutant name-without-attempt 's|-${{ github.run_attempt }}||'
expect 'an artifact name without the run attempt is refused' \
  'the name must carry the run id and the run attempt' "$WORK/name-without-attempt.yml"

mutant upload-old-name 's|name: ${{ env.ARTIFACT_NAME }}|name: review-pool-acceptance-${{ github.run_id }}|'
expect 'an upload under another name than the output is refused' \
  'the upload must use the one defined name' "$WORK/upload-old-name.yml"

mutant no-secret '/^      ANTHROPIC_API_KEY:$/,/^        required: false$/d'
expect 'a call that declares fewer than the three credentials is refused' \
  'must declare the three backend credentials' "$WORK/no-secret.yml"

mutant no-effort-input '0,/^      effort:$/s|^      effort:$|      effortx:|'
expect 'a call whose inputs differ from the dispatch inputs is refused' \
  'the same four inputs' "$WORK/no-effort-input.yml"

mutant registry-field-back \
  's|^\( *\)printf .bundle_record_sha256=.*$|&\n\1printf registry_latest_digest=x|'
expect 'a record that carries a registry digest field again is refused' \
  'must not read the registry or carry a registry digest field' "$WORK/registry-field-back.yml"

mutant registry-read-back \
  's|^\( *\)bundle_sha=.*$|&\n\1curl -fsS https://ghcr.io/token|'
expect 'a step that reads the registry token again is refused' \
  'must not read the registry or carry a registry digest field' "$WORK/registry-read-back.yml"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
