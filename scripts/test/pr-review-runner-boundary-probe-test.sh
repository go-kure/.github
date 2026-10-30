#!/usr/bin/env bash
# pr-review-runner-boundary-probe-test.sh — fixture tests for
# scripts/pr-review-runner-boundary-probe.sh.
#
# The probe is an acceptance test: its one way to be wrong that matters is to pass without
# having looked. These tests feed its judge synthetic reports and run its stub with a
# descriptor open, so each way a result can be void (no control, a malformed field, a mount
# experiment that never ran, a descriptor out of the scanned range) is shown to end in a
# non-zero exit, and a clean pair is shown to pass. They invoke the script itself.
#
# Usage: pr-review-runner-boundary-probe-test.sh [REPO_ROOT]

set -uo pipefail # not -e: report every assertion, not just the first failure

ROOT="${1:-.}"
ROOT="$(cd "$ROOT" && pwd)"
PROBE="$ROOT/scripts/pr-review-runner-boundary-probe.sh"

failures=0
pass_count=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $desc — expected '$expected', got '$actual'" >&2
    failures=$((failures + 1))
  fi
}

dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT

# A report the way the stub writes it. Overrides are KEY=VALUE words that replace a line;
# KEY= (empty) writes an empty field and KEY=@ drops the line.
write_report() { # write_report FILE KIND [KEY=VALUE...]
  local file="$1" kind="$2" line key; shift 2
  local -a lines
  if [ "$kind" = boundary ]; then
    lines=(canary_hits=0 ancestor_environ_open=0 ancestor_mem_open=0 fd_above_2=0
      uid=1000 cap_eff=0000000000000000 cap_bnd=000001ffffffffff no_new_privs=0
      proc_mount=denied pids_visible=1)
  else
    lines=(canary_hits=1 ancestor_environ_open=6 ancestor_mem_open=6 fd_above_2=0
      uid=1000 cap_eff=0000000000000000 cap_bnd=000001ffffffffff no_new_privs=0
      proc_mount=skipped pids_visible=900)
  fi
  : > "$file"
  for line in "${lines[@]}"; do
    key="${line%%=*}"
    for o in "$@"; do
      if [ "${o%%=*}" = "$key" ]; then line="$o"; fi
    done
    [ "${line#*=}" = "@" ] || printf '%s\n' "$line" >> "$file"
  done
}

judge_rc() { # judge_rc BOUNDARY CONTROL -> exit code of the judge
  bash "$PROBE" judge "$1" "$2" > /dev/null 2>&1
  echo $?
}

write_report "$dir/b" boundary
write_report "$dir/c" control
assert_eq "judge: a clean boundary and a control that saw the canary pass" 0 "$(judge_rc "$dir/b" "$dir/c")"

# The control is what makes the boundary result mean anything.
assert_eq "judge: no control report is inconclusive, not a pass" 3 "$(judge_rc "$dir/b" "$dir/none")"
write_report "$dir/c1" control canary_hits=
assert_eq "judge: a control with an empty canary count is inconclusive" 3 "$(judge_rc "$dir/b" "$dir/c1")"
write_report "$dir/c2" control canary_hits=0
assert_eq "judge: a control that did not see the canary is inconclusive" 3 "$(judge_rc "$dir/b" "$dir/c2")"
write_report "$dir/c3" control ancestor_environ_open=0
assert_eq "judge: a control that opened no ancestor environ is inconclusive" 3 "$(judge_rc "$dir/b" "$dir/c3")"
write_report "$dir/c4" control canary_hits=x
assert_eq "judge: a control with a non-numeric count is inconclusive" 3 "$(judge_rc "$dir/b" "$dir/c4")"
write_report "$dir/c5" control ancestor_environ_open=@
assert_eq "judge: a control missing a field is inconclusive" 3 "$(judge_rc "$dir/b" "$dir/c5")"
: > "$dir/c6"
assert_eq "judge: an empty control report is inconclusive" 3 "$(judge_rc "$dir/b" "$dir/c6")"

# A leak is a leak.
write_report "$dir/b1" boundary canary_hits=1
assert_eq "judge: the canary found behind the boundary fails" 1 "$(judge_rc "$dir/b1" "$dir/c")"
write_report "$dir/b2" boundary ancestor_environ_open=1
assert_eq "judge: an ancestor environ opened behind the boundary fails" 1 "$(judge_rc "$dir/b2" "$dir/c")"
write_report "$dir/b3" boundary ancestor_mem_open=2
assert_eq "judge: an ancestor mem opened behind the boundary fails" 1 "$(judge_rc "$dir/b3" "$dir/c")"
write_report "$dir/b4" boundary fd_above_2=1
assert_eq "judge: a descriptor above 2 behind the boundary fails" 1 "$(judge_rc "$dir/b4" "$dir/c")"
write_report "$dir/b5" boundary cap_eff=0000000000000400
assert_eq "judge: a capability behind the boundary fails" 1 "$(judge_rc "$dir/b5" "$dir/c")"
write_report "$dir/b6" boundary proc_mount=succeeded
assert_eq "judge: a procfs mount that worked behind the boundary fails" 1 "$(judge_rc "$dir/b6" "$dir/c")"
write_report "$dir/b7" boundary uid=0 cap_bnd=000001ffffffffff
assert_eq "judge: root with a full bounding set behind the boundary fails" 1 "$(judge_rc "$dir/b7" "$dir/c")"
write_report "$dir/b8" boundary uid=0 cap_bnd=0000000000000000
assert_eq "judge: root with an empty bounding set passes" 0 "$(judge_rc "$dir/b8" "$dir/c")"

# A step that could not be tried is not a step that was denied.
write_report "$dir/m1" boundary proc_mount=untried:no-mount-command
assert_eq "judge: a mount experiment that could not run is inconclusive" 3 "$(judge_rc "$dir/m1" "$dir/c")"
write_report "$dir/m2" boundary proc_mount=failed:127
assert_eq "judge: a mount failure that is not a denial is inconclusive" 3 "$(judge_rc "$dir/m2" "$dir/c")"
write_report "$dir/m3" boundary proc_mount=skipped
assert_eq "judge: a boundary whose mount experiment was skipped is inconclusive" 3 "$(judge_rc "$dir/m3" "$dir/c")"
write_report "$dir/m4" boundary fd_above_2=@
assert_eq "judge: a boundary report missing a field is inconclusive" 3 "$(judge_rc "$dir/m4" "$dir/c")"
write_report "$dir/m5" boundary cap_eff=zz
assert_eq "judge: a boundary report with a malformed capability set is inconclusive" 3 "$(judge_rc "$dir/m5" "$dir/c")"
assert_eq "judge: no boundary report is inconclusive" 3 "$(judge_rc "$dir/none" "$dir/c")"
assert_eq "judge: a leak is still a leak when the control is missing" 1 "$(judge_rc "$dir/b1" "$dir/none")"

# The stub: run with a descriptor open, under the environment the probe gives it.
printf 'canary-for-the-test' > "$dir/canary"
stub_run() { # stub_run REPORT [env words...] — descriptor 300 is open when PRT_TEST_FD300 is set
  local report="$1"; shift
  rm -f "$report"
  if [ -n "${PRT_TEST_FD300:-}" ]; then
    (
      exec 300< /dev/null
      env -i PATH="$PATH" PRT_PROBE_REPORT="$report" PRT_PROBE_CANARY_FILE="$dir/canary" PRT_PROBE_ANCESTORS="" \
        PRT_HEAD_SHA=a PRT_REVIEW_BASE_SHA=b PRT_REVIEW_MATERIAL_SHA256=c "$@" \
        bash "$PROBE" stub --out "$dir/out.$$" < /dev/null > /dev/null 2>&1
    )
  else
    env -i PATH="$PATH" PRT_PROBE_REPORT="$report" PRT_PROBE_CANARY_FILE="$dir/canary" PRT_PROBE_ANCESTORS="" \
      PRT_HEAD_SHA=a PRT_REVIEW_BASE_SHA=b PRT_REVIEW_MATERIAL_SHA256=c "$@" \
      bash "$PROBE" stub --out "$dir/out.$$" < /dev/null > /dev/null 2>&1
  fi
  rm -rf "$dir/out.$$"
}
field() { sed -n "s/^$2=//p" "$1" 2> /dev/null | head -1; }

stub_run "$dir/s0"
assert_eq "stub: no descriptor above 2 is reported when none is open" 0 "$(field "$dir/s0" fd_above_2)"
PRT_TEST_FD300=1 stub_run "$dir/s1"
assert_eq "stub: a descriptor 300 left open is reported" 1 "$(field "$dir/s1" fd_above_2)"

# The mount experiment is off unless asked for, and refuses to run in the orchestrator's own
# mount namespace: nothing it mounts may outlive it.
stub_run "$dir/s2"
assert_eq "stub: the mount experiment is skipped by default" skipped "$(field "$dir/s2" proc_mount)"
stub_run "$dir/s3" PRT_PROBE_MOUNT=try PRT_PROBE_PARENT_MNT_NS="$(readlink /proc/self/ns/mnt)"
assert_eq "stub: the mount experiment will not run in the caller's mount namespace" \
  untried:shares-mount-namespace "$(field "$dir/s3" proc_mount)"
stub_run "$dir/s4" PRT_PROBE_MOUNT=try
assert_eq "stub: the mount experiment will not run without the caller's mount namespace" \
  untried:mount-namespace-unreadable "$(field "$dir/s4" proc_mount)"

# A stand-in `mount` and `readlink` first on the stub's PATH: no real mount is ever tried. The
# stub sees a parent namespace that differs from its own, so the experiment is allowed to run.
mkdir "$dir/fakebin"
cat > "$dir/fakebin/mount" <<'EOF'
#!/bin/sh
echo "$FAKE_MOUNT_MSG" >&2
exit "$FAKE_MOUNT_RC"
EOF
cat > "$dir/fakebin/readlink-empty" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod 755 "$dir/fakebin/mount" "$dir/fakebin/readlink-empty"
mount_case() { # mount_case REPORT RC MESSAGE
  stub_run "$1" PATH="$dir/fakebin:$PATH" PRT_PROBE_MOUNT=try PRT_PROBE_PARENT_MNT_NS=mnt:[1] \
    FAKE_MOUNT_RC="$2" FAKE_MOUNT_MSG="$3"
  field "$1" proc_mount
}
assert_eq "stub: a refusal by mount itself is a denial" denied \
  "$(mount_case "$dir/t1" 32 'mount: /x: must be superuser to use mount.')"
assert_eq "stub: a mount tool that cannot be executed (126) is not a denial" failed:126 \
  "$(mount_case "$dir/t2" 126 'mount: Permission denied')"
assert_eq "stub: a missing mount tool (127) is not a denial" failed:127 \
  "$(mount_case "$dir/t3" 127 'mount: not found')"
assert_eq "stub: an unrelated mount failure is not a denial" failed:32 \
  "$(mount_case "$dir/t4" 32 'mount: /x: unknown filesystem type proc.')"
cp "$dir/fakebin/readlink-empty" "$dir/fakebin/readlink"
assert_eq "stub: an unreadable own mount namespace does not run the experiment" untried:mount-namespace-unreadable \
  "$(mount_case "$dir/t5" 32 'mount: /x: must be superuser to use mount.')"
rm -f "$dir/fakebin/readlink"

# A number too big for bash arithmetic must not slip past the comparisons.
write_report "$dir/n1" boundary canary_hits=18446744073709551616
assert_eq "judge: an oversized boundary count is inconclusive" 3 "$(judge_rc "$dir/n1" "$dir/c")"
write_report "$dir/n2" control canary_hits=18446744073709551616
assert_eq "judge: an oversized control count is inconclusive" 3 "$(judge_rc "$dir/b" "$dir/n2")"
write_report "$dir/n3" boundary uid=99999999999999999999
assert_eq "judge: an oversized uid is inconclusive" 3 "$(judge_rc "$dir/n3" "$dir/c")"
assert_eq "judge: an oversized count raises no arithmetic error" "" \
  "$(bash "$PROBE" judge "$dir/n1" "$dir/c" 2>&1 >/dev/null)"

echo "passed: $pass_count, failed: $failures"
[ "$failures" -eq 0 ]
