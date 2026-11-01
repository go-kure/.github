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
      uid=1000 cap_eff=0000000000000000 cap_bnd=000001ffffffffff no_new_privs=1
      proc_mount=denied canary_state=ok own_environ_open=1 own_environ_marker=1
      environ_entries=40 own_environ_listed=1)
  else
    lines=(canary_hits=1 ancestor_environ_open=6 ancestor_mem_open=6 fd_above_2=0
      uid=1000 cap_eff=0000000000000000 cap_bnd=000001ffffffffff no_new_privs=0
      proc_mount=skipped canary_state=ok own_environ_open=1 own_environ_marker=1)
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
write_report "$dir/b9" boundary no_new_privs=0
assert_eq "judge: a boundary without no-new-privs fails" 1 "$(judge_rc "$dir/b9" "$dir/c")"
write_report "$dir/b10" boundary uid=0 cap_bnd=0000000000000000 no_new_privs=0
assert_eq "judge: root without no-new-privs fails" 1 "$(judge_rc "$dir/b10" "$dir/c")"

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
write_report "$dir/m6" boundary no_new_privs=
assert_eq "judge: an empty no-new-privs value is inconclusive" 3 "$(judge_rc "$dir/m6" "$dir/c")"
write_report "$dir/m7" boundary no_new_privs=@
assert_eq "judge: a missing no-new-privs line is inconclusive" 3 "$(judge_rc "$dir/m7" "$dir/c")"
write_report "$dir/m8" boundary no_new_privs=2
assert_eq "judge: a no-new-privs value of 2 is inconclusive" 3 "$(judge_rc "$dir/m8" "$dir/c")"
assert_eq "judge: no boundary report is inconclusive" 3 "$(judge_rc "$dir/none" "$dir/c")"
assert_eq "judge: a leak is still a leak when the control is missing" 1 "$(judge_rc "$dir/b1" "$dir/none")"

# The stub: run with a descriptor open, under the environment the probe gives it.
printf 'canary-for-the-test' > "$dir/canary"
stub_run() { # stub_run REPORT [env words...] — descriptor 300 is open when PRT_TEST_FD300 is set
  local report="$1"; shift
  rm -f "$report"
  (
    # The probe counts every descriptor above 2 it inherits, so start it from a shell that has closed
    # the ones its own caller (a CI step, a harness) handed down: "none is open" is then the test's
    # premise, not the environment's.
    for p in /proc/self/fd/*; do
      n="${p##*/}"
      [ "$n" -gt 2 ] 2> /dev/null || continue
      eval "exec $n>&-" 2> /dev/null || true
    done
    if [ -n "${PRT_TEST_FD300:-}" ]; then exec 300< /dev/null; fi
    env -i PATH="$PATH" PRT_PROBE_REPORT="$report" PRT_PROBE_CANARY_FILE="$dir/canary" PRT_PROBE_ANCESTORS="" \
      PRT_HEAD_SHA=marker-for-the-test-1234 PRT_REVIEW_BASE_SHA=b PRT_REVIEW_MATERIAL_SHA256=c "$@" \
      bash "$PROBE" stub --out "$dir/out.$$" < /dev/null > /dev/null 2>&1
  )
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

# A scan that is blind inside the boundary must not read as "nothing found". The stub looks
# for a known, non-secret marker (its own head SHA) in its own environment with the same scan.
stub_run "$dir/k0"
assert_eq "stub: the scan finds the marker in the stub's own environment" 1 "$(field "$dir/k0" own_environ_marker)"
assert_eq "stub: the stub can open its own environ" 1 "$(field "$dir/k0" own_environ_open)"
assert_eq "stub: the scan listed the process table and found the stub's own entry" "1 1" \
  "$([ "$(field "$dir/k0" environ_entries)" -ge 1 ] 2> /dev/null && echo 1 || echo 0) $(field "$dir/k0" own_environ_listed)"
# The scan reads the files itself: no grep, tr or sed stands between it and the answer, so a
# tool that fails (or behaves differently from one implementation to the next) changes nothing.
mkdir "$dir/shim"
printf '#!/bin/sh\nexit 2\n' > "$dir/shim/grep"
printf '#!/bin/sh\nexit 1\n' > "$dir/shim/tr"
chmod 755 "$dir/shim/grep" "$dir/shim/tr"
stub_run "$dir/k1" PATH="$dir/shim:$PATH"
assert_eq "stub: a grep and a tr that fail leave the marker found" 1 "$(field "$dir/k1" own_environ_marker)"
assert_eq "stub: a grep and a tr that fail leave the stub's own entry listed" 1 "$(field "$dir/k1" own_environ_listed)"
write_report "$dir/k3" boundary own_environ_marker=0
assert_eq "judge: a boundary scan that cannot find the marker is inconclusive" 3 "$(judge_rc "$dir/k3" "$dir/c")"
write_report "$dir/k4" boundary own_environ_open=0
assert_eq "judge: a boundary that cannot open its own environ is inconclusive" 3 "$(judge_rc "$dir/k4" "$dir/c")"
write_report "$dir/k5" boundary own_environ_marker=@
assert_eq "judge: a boundary report without the marker field is inconclusive" 3 "$(judge_rc "$dir/k5" "$dir/c")"
write_report "$dir/k6" boundary canary_state=missing
assert_eq "judge: a boundary whose stub had no canary to look for is inconclusive" 3 "$(judge_rc "$dir/k6" "$dir/c")"
write_report "$dir/k6b" boundary canary_hits=
assert_eq "judge: a boundary with no canary count is inconclusive" 3 "$(judge_rc "$dir/k6b" "$dir/c")"
write_report "$dir/k6c" boundary fd_above_2=
assert_eq "judge: a boundary whose descriptor listing gave no count is inconclusive" 3 "$(judge_rc "$dir/k6c" "$dir/c")"
write_report "$dir/k7" boundary canary_hits=1 own_environ_marker=0
assert_eq "judge: a leak is still a leak when the scan is blind" 1 "$(judge_rc "$dir/k7" "$dir/c")"

# The hit count comes from one scan of the process table; a report in which that scan listed
# nothing, or not the stub itself, must not pass on the strength of other checks that read 1.
write_report "$dir/e1" boundary environ_entries=0
assert_eq "judge: a scan that listed no process is inconclusive, whatever the other checks read" 3 "$(judge_rc "$dir/e1" "$dir/c")"
write_report "$dir/e2" boundary own_environ_listed=0
assert_eq "judge: a scan that did not list the stub's own entry is inconclusive" 3 "$(judge_rc "$dir/e2" "$dir/c")"
write_report "$dir/e3" boundary environ_entries=@
assert_eq "judge: a boundary report without the entry count is inconclusive" 3 "$(judge_rc "$dir/e3" "$dir/c")"
write_report "$dir/e4" boundary own_environ_listed=@
assert_eq "judge: a boundary report without the own-entry field is inconclusive" 3 "$(judge_rc "$dir/e4" "$dir/c")"
write_report "$dir/e5" boundary environ_entries=
assert_eq "judge: an empty entry count is inconclusive" 3 "$(judge_rc "$dir/e5" "$dir/c")"
write_report "$dir/e6" boundary canary_hits=1 environ_entries=0
assert_eq "judge: a leak is still a leak when the scan listed nothing" 1 "$(judge_rc "$dir/e6" "$dir/c")"
# End to end: a real stub whose listing found nothing (globbing off leaves the pattern literal,
# which is no entry) reports zero hits, and its own marker is read straight from its own file.
# That pair is exactly what passed before the scan counted what it listed.
stub_run "$dir/e7" SHELLOPTS=noglob
assert_eq "stub: a process-table listing that gave nothing reports no entry" "0 0" \
  "$(field "$dir/e7" environ_entries) $(field "$dir/e7" own_environ_listed)"
# Otherwise-clean boundary reports that carry the stub's real scan fields: only these differ.
write_report "$dir/e8" boundary environ_entries="$(field "$dir/e7" environ_entries)" own_environ_listed="$(field "$dir/e7" own_environ_listed)"
assert_eq "judge: ... and that scan's report is inconclusive, not a pass" 3 "$(judge_rc "$dir/e8" "$dir/c")"
write_report "$dir/e9" boundary environ_entries="$(field "$dir/k0" environ_entries)" own_environ_listed="$(field "$dir/k0" own_environ_listed)"
assert_eq "judge: a working scan's fields in an otherwise clean report pass" 0 "$(judge_rc "$dir/e9" "$dir/c")"

# A descriptor listing that fails must not read as "no descriptors". With globbing off the listing
# stays a literal pattern: the stub saw none of the standard descriptors, so it writes an empty
# count, which the judge reads as unusable. A working listing is counted from 0 up.
stub_run "$dir/f0" SHELLOPTS=noglob
assert_eq "stub: a descriptor listing that did not work leaves the count empty, not 0" \
  "present-empty" "$(grep -q '^fd_above_2=$' "$dir/f0" && echo present-empty || echo "other:$(field "$dir/f0" fd_above_2)")"

# GNU grep quits at its first match when its output is /dev/null (ugrep does not), which left `tr`
# writing into a closed pipe: under pipefail the pipeline was then 141 and a match read as a miss,
# on one host and not another. The scan no longer has a pipe or a grep. A match first in an
# environment far larger than a pipe buffer must be found, with grep and tr both failing.
big="$(head -c 100000 /dev/zero | tr '\0' x)"
stub_run "$dir/g0" PATH="$dir/shim:$PATH" LEAKED=canary-for-the-test BIG1="$big" BIG2="$big" BIG3="$big"
assert_eq "stub: the marker is found in an environment larger than a pipe buffer" 1 "$(field "$dir/g0" own_environ_marker)"
assert_eq "stub: the canary placed first in a large environment is counted" 1 "$(field "$dir/g0" canary_hits)"
# The function itself, on files: a match first in a 5 MB environ, a match last without its NUL,
# no match, an empty file, a missing file, an unreadable one.
big5="$(head -c 5000000 /dev/zero | tr '\0' y)"
printf 'FIRST=needle-1\0BIG=%s\0' "$big5" > "$dir/e.first"
printf 'A=1\0B=2\0LAST=needle-2' > "$dir/e.last"
printf 'A=1\0B=2\0' > "$dir/e.none"
: > "$dir/e.empty"
# shellcheck disable=SC2016 # the script text is for the inner shell
has_script='source "$1"; shift
for spec in "$@"; do
  if environ_has "${spec%%|*}" "${spec##*|}" 2> /dev/null; then printf "yes "; else printf "no "; fi
done'
# An empty PATH: only builtins are left, so the answer cannot depend on any external tool.
assert_eq "environ_has: a first match in a 5 MB environ, a last match with no NUL, and four misses, with no external command" \
  "yes yes no no no no " \
  "$(env -i PATH="$dir/no-such-dir" "$BASH" -c "$has_script" _ "$PROBE" \
    "$dir/e.first|needle-1" "$dir/e.last|needle-2" "$dir/e.none|needle-1" "$dir/e.empty|needle-1" \
    "$dir/e.missing|needle-1" "$dir|needle-1" 2> /dev/null)"

# An empty or missing canary would match every environment: it is named, not scanned for.
: > "$dir/canary-empty"
stub_run "$dir/h0" PRT_PROBE_CANARY_FILE="$dir/canary-empty"
assert_eq "stub: an empty canary file gives no canary count" "present-empty" \
  "$(grep -q '^canary_hits=$' "$dir/h0" && echo present-empty || echo "other:$(field "$dir/h0" canary_hits)")"
assert_eq "stub: an empty canary file is named" empty "$(field "$dir/h0" canary_state)"
stub_run "$dir/h1" PRT_PROBE_CANARY_FILE="$dir/no-such-canary"
assert_eq "stub: a missing canary file gives no canary count" "present-empty" \
  "$(grep -q '^canary_hits=$' "$dir/h1" && echo present-empty || echo "other:$(field "$dir/h1" canary_hits)")"
assert_eq "stub: a missing canary file is named" missing "$(field "$dir/h1" canary_state)"
stub_run "$dir/h2"
assert_eq "stub: a readable canary is reported as such" ok "$(field "$dir/h2" canary_state)"

# Who the stub is and where it sits, as informational fields.
assert_eq "stub: it reports its user name" "$(id -un)" "$(field "$dir/h2" user)"
assert_eq "stub: it reports its namespace identity (here: not in a namespace of its own, parent unknown)" \
  "true unknown" "$([ -n "$(field "$dir/h2" nspid)" ] && echo true || echo false) $(field "$dir/h2" pid_ns_differs)"
stub_run "$dir/h3" PRT_PROBE_PARENT_PID_NS="$(readlink /proc/self/ns/pid)"
assert_eq "stub: the same pid namespace as the parent is reported as 0" 0 "$(field "$dir/h3" pid_ns_differs)"
stub_run "$dir/h4" PRT_PROBE_PARENT_PID_NS="pid:[1]"
assert_eq "stub: a different pid namespace is reported as 1" 1 "$(field "$dir/h4" pid_ns_differs)"

# The whole run, with stand-ins that break one step. Only where this host can start the
# boundary at all: elsewhere the run itself reports exit 2 and the cases would say nothing.
run_rc() { # run_rc [env words...] -> exit code of a full run
  env "$@" bash "$PROBE" run > /dev/null 2>&1
  echo $?
}
# These stop before the boundary is tried, so they run on any host.
assert_eq "run: a probe that cannot load the orchestrator's functions is a setup failure" 4 \
  "$(mkdir -p "$dir/solo/scripts" && cp "$PROBE" "$dir/solo/scripts/" && env bash "$dir/solo/scripts/pr-review-runner-boundary-probe.sh" run > /dev/null 2>&1; echo $?)"
mkdir -p "$dir/nochmod"
printf '#!/bin/sh\nexit 1\n' > "$dir/nochmod/chmod"
chmod 755 "$dir/nochmod/chmod"
assert_eq "run: a stand-in runner that cannot be made executable is a setup failure" 4 "$(run_rc PATH="$dir/nochmod:$PATH")"
assert_eq "run: an orchestrator refusal before the boundary (a floor that is not a number) is a setup failure, not a leak" 4 \
  "$(run_rc PRT_MODEL_TIMEOUT_FLOOR=soon)"

# An inherited re-exec marker, or a real token, must never be written to the work file as the canary.
# The `uname` stand-in runs after the file is written and keeps a copy of it.
mkdir -p "$dir/tw" "$dir/rx"
real_uname="$(command -v uname)"
# shellcheck disable=SC2016 # the stand-in's own text, not an expansion here
printf '#!/bin/sh\ncp "$TMPDIR"/tmp.*/canary "$CANARY_COPY" 2>/dev/null\nexec %s "$@"\n' "$real_uname" > "$dir/rx/uname"
printf '#!/bin/sh\nexit 1\n' > "$dir/rx/unshare"
chmod 755 "$dir/rx/uname" "$dir/rx/unshare"
for marker in 1 real-secret-value-0123456789abcdef; do
  rm -f "$dir/canary-copy"
  env TMPDIR="$dir/tw" CANARY_COPY="$dir/canary-copy" PATH="$dir/rx:$PATH" PRT_PROBE_REEXEC="$marker" \
    PRT_GH_TOKEN=real-secret-value-0123456789abcdef bash "$PROBE" run > /dev/null 2>&1
  assert_eq "run: with PRT_PROBE_REEXEC=$marker and a real token set, the work file holds a fresh canary" "true" \
    "$(grep -qE '^probe-canary-[0-9a-f]{32}$' "$dir/canary-copy" 2> /dev/null && echo true || echo false)"
done

# A failed re-exec ends a shell with 126 or 127 unless told otherwise; the probe's codes are 0 to 4.
# bash, od, tr, dirname and basename are on this PATH, `env` is not, so only the re-exec can fail.
mkdir -p "$dir/noenv"
for t in bash od tr dirname basename; do ln -sf "$(command -v "$t")" "$dir/noenv/$t"; done
exec_out="$(env -i PATH="$dir/noenv" "$dir/noenv/bash" "$PROBE" run 2>&1)"
exec_rc=$?
assert_eq "run: a re-exec that cannot start is a setup failure (4), not 126 or 127" 4 "$exec_rc"
assert_eq "run: ... and it says so" "true" "$([[ "$exec_out" == *"cannot start the probe again"* ]] && echo true || echo false)"

# The lane lines: a failing command is a marker, never an empty field; the messages of unshare
# lose their absolute paths like the orchestrator's own.
mkdir -p "$dir/lane"
printf '#!/bin/sh\nexit 1\n' > "$dir/lane/id"
printf '#!/bin/sh\nexit 1\n' > "$dir/lane/uname"
printf '#!/bin/sh\necho "unshare: cannot open /private/outside/the/workspace/ns: denied" >&2\nexit 1\n' > "$dir/lane/unshare"
chmod 755 "$dir/lane/id" "$dir/lane/uname" "$dir/lane/unshare"
mkdir -p "$dir/lane-tmp"
lane_out="$(env TMPDIR="$dir/lane-tmp" PATH="$dir/lane:$PATH" bash "$PROBE" run 2> /dev/null)"
assert_eq "run: a failing uname and id give markers in the lane lines" "true" \
  "$([[ "$lane_out" == *"lane: kernel=n/a uid=n/a os="* && "$lane_out" == *"lane: orchestrator user=n/a groups=n/a"* ]] && echo true || echo false)"
assert_eq "run: no lane line has an empty field" "" "$(printf '%s\n' "$lane_out" | grep -E '^lane: .*(=$|= )' || true)"
assert_eq "run: an unshare message keeps its words and loses its absolute path" "true" \
  "$([[ "$lane_out" == *"failed rc=1 unshare: cannot open <path>: denied"* && "$lane_out" != *"/private/outside"* ]] && echo true || echo false)"

# The ancestor chain is parsed from /proc/PID/stat, whose fields after the command name are plain
# words: both the parent and the start time must be numbers, or the chain would end short.
stat_case() { # stat_case LINE -> "ppid start" or "fail"
  bash -c 'source "$1"; if stat_fields "$2"; then echo "$STAT_PPID $STAT_START"; else echo fail; fi' _ "$PROBE" "$1" 2> /dev/null
}
stat_fill="0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0" # fields 3 to 18 after the state, 17 words
assert_eq "stat: a parent and a start time are read" "77 12345" "$(stat_case "1 (bash) S 77 $stat_fill 12345 0 0")"
assert_eq "stat: a start time of 11 digits (a long uptime) is read" "77 12345678901" "$(stat_case "1 (bash) S 77 $stat_fill 12345678901 0")"
assert_eq "stat: a command name with ') ' in it is skipped as a whole" "77 12345" "$(stat_case "1 (a) b) S 77 $stat_fill 12345 0")"
assert_eq "stat: an empty parent field fails" fail "$(stat_case "1 (bash) S")"
assert_eq "stat: a parent that is not a number fails" fail "$(stat_case "1 (bash) S x $stat_fill 12345 0")"
assert_eq "stat: a start time that is not a number fails" fail "$(stat_case "1 (bash) S 77 $stat_fill x 0")"
assert_eq "stat: a line too short for the start time fails" fail "$(stat_case "1 (bash) S 77 0 0 0")"
assert_eq "stat: an empty line fails" fail "$(stat_case "")"

if [ -z "${PRT_TEST_FORCE_NO_NAMESPACE:-}" ] && unshare --user --map-current-user --pid --fork --mount-proc true > /dev/null 2>&1; then
  assert_eq "run: an unreadable own mount namespace is a setup failure" 4 \
    "$(mkdir -p "$dir/rl" && printf '#!/bin/sh\nexit 1\n' > "$dir/rl/readlink" && chmod 755 "$dir/rl/readlink" && run_rc PATH="$dir/rl:$PATH")"
  assert_eq "run: a boundary that cannot start is reported as not established" 2 \
    "$(mkdir -p "$dir/un" && printf '#!/bin/sh\nexit 1\n' > "$dir/un/unshare" && chmod 755 "$dir/un/unshare" && run_rc PATH="$dir/un:$PATH")"
  assert_eq "run: a call that succeeds but whose stub cannot write its report is inconclusive, not a leak" 3 \
    "$(mkdir -p "$dir/sh" && printf '#!/bin/sh\nexit 1\n' > "$dir/sh/mv" && chmod 755 "$dir/sh/mv" && run_rc PATH="$dir/sh:$PATH")"
  # The "no descriptor" judgement needs something to find: the probe holds a descriptor open across
  # the production call. With the call's descriptor closing switched off in a copy of the
  # orchestrator, that descriptor reaches the stub and the run must report it as a leak.
  mkdir -p "$dir/mut/scripts/lib"
  cp "$PROBE" "$dir/mut/scripts/"
  cp -R "$(dirname "$PROBE")/lib/prt" "$dir/mut/scripts/lib/"
  # shellcheck disable=SC2016 # the pattern is the orchestrator's own text, not an expansion here
  sed -i 's/if \[ "\$prt_fd" -gt 2 \] 2>\/dev\/null; then eval "exec \$prt_fd>&-"; fi/:/' "$dir/mut/scripts/lib/prt/model.sh"
  # shellcheck disable=SC2016 # same: a literal pattern
  assert_eq "run: the descriptor-closing mutant is really in the copy" 0 \
    "$(grep -c 'eval "exec \$prt_fd>&-"' "$dir/mut/scripts/lib/prt/model.sh" || true)"
  mut_out="$(env bash "$dir/mut/scripts/$(basename "$PROBE")" run 2> /dev/null)"
  mut_rc=$?
  assert_eq "run: a call that keeps the probe's open descriptor is a leak (1)" 1 "$mut_rc"
  assert_eq "run: ... and the leak names the descriptor count" "true" \
    "$([[ "$mut_out" == *"LEAK: boundary: fd_above_2 is "* ]] && echo true || echo false)"
  # A call that fails after the boundary stands: the stub cannot make its output directory, so the
  # call ends as runner-no-output behind the production boundary.
  assert_eq "run: a call that fails after the boundary stands is a failure" 1 \
    "$(mkdir -p "$dir/nm" && printf '#!/bin/sh\nexit 1\n' > "$dir/nm/mkdir" && chmod 755 "$dir/nm/mkdir" && run_rc PATH="$dir/nm:$PATH")"
else
  # A silent skip would read as a pass. PRT_TEST_REQUIRE_NAMESPACE=1 (set by the lane that must run
  # these cases) turns it into a failure.
  echo "NOTE: this host forbids the PID namespace the default boundary needs: the full-run cases are skipped; a lane that can run them is required for acceptance"
  assert_eq "no PID namespace here: PRT_TEST_REQUIRE_NAMESPACE is not set (the full-run cases did not run)" \
    "" "${PRT_TEST_REQUIRE_NAMESPACE:-}"
fi

echo "passed: $pass_count, failed: $failures"
[ "$failures" -eq 0 ]
