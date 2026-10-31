#!/usr/bin/env bash
# pr-review-runner-boundary-probe.sh — acceptance run for the runner's process boundary
# (PRT_ASSESS_BACKEND=runner, see docs/pr-review-threads.md "Process boundary").
#
# It shows, on the host it runs on, whether a runner started the way the orchestrator
# starts it can read the posting token. It uses a made-up canary in place of the token and a
# stub in place of the real runner: no secret, no model call, no forge access. The stub reads
# /proc and makes one attempt to mount a procfs, only inside the boundary's own mount
# namespace (it refuses to try in any other), so nothing it does outlives it. The canary is
# placed in this script's own environment at exec time, so it sits where the posting token
# sits for the orchestrator, in an ancestor's /proc/<pid>/environ.
#
#   probe.sh            run: both probes below, then the judge
#   probe.sh judge B C  judge two reports (files), print the verdict
#   probe.sh stub ...   the stand-in runner; started by run, not by hand
#
# Two probes run, both through the same environment scrub and descriptor closing:
#   boundary  the production call, _prt_call_runner (default boundary, checked, bounded)
#   control   the same stub with `env -i` only, no boundary, and no mount experiment
# The control must show the canary through an ancestor. A result without that proves nothing.
#
# Exit codes: 0 the boundary holds and the control saw the canary; 1 the boundary leaks (or
# the call failed after the boundary was established); 2 the boundary cannot be established
# here; 3 inconclusive: the control, a field or the mount experiment did not give a usable
# answer, so no pass can be claimed; 4 the probe could not set itself up (or the call was
# refused before the stub could run, which says nothing about the boundary).
set -uo pipefail

self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# ---------------------------------------------------------------------------------------
# report files: KEY=VALUE lines
# ---------------------------------------------------------------------------------------
get() { sed -n "s/^$2=//p" "$1" 2> /dev/null | head -1; }
# At most 9 digits: a longer string would make bash arithmetic comparisons error out.
is_count() { [[ "${1:-}" =~ ^[0-9]{1,9}$ ]]; }
is_caps() { [[ "${1:-}" =~ ^[0-9a-f]{16}$ ]]; }
# environ_has FILE VALUE: does the NUL-separated environ FILE hold VALUE? Errors read as "no".
# grep reads to the end (no -q): under pipefail a grep that quit at the first match would leave
# tr writing into a closed pipe, and the pipeline would return 141, a match read as a miss.
environ_has() { { tr '\0' '\n' < "$1"; } 2> /dev/null | grep -F -- "$2" > /dev/null; }

# ---------------------------------------------------------------------------------------
# stub: what a runner could reach, written to $PRT_PROBE_REPORT, then a clean answer
# ---------------------------------------------------------------------------------------
probe_stub() {
  local out="" req canary a p st f s n e mnt msg rc own_ns pid_ns nspid key canary_state=ok
  local pid_ns_differs=unknown
  local anc_environ=0 anc_mem=0 hits=0 fd_above2=0 fd_std=0 mount_result=skipped own_open=0 own_marker=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --out) out="$2"; shift 2 ;;
      --) shift; break ;;
      --backend|--root|--base|--seconds|--sandbox) shift 2 ;;
      *) shift ;;
    esac
  done
  req="$(cat)"
  # An empty canary would match every readable environment (grep -F "" matches any line): a
  # canary that cannot be read, or is empty, is reported as such and nothing is scanned for it.
  canary=""
  if [ -r "${PRT_PROBE_CANARY_FILE:-}" ]; then canary="$(cat "$PRT_PROBE_CANARY_FILE")" || canary=""; else canary_state=missing; fi
  [ -n "$canary" ] || { [ "$canary_state" != ok ] || canary_state=empty; }
  if [ "$canary_state" = ok ]; then
    shopt -s nullglob
    for e in /proc/[0-9]*/environ; do
      if environ_has "$e" "$canary"; then hits=$((hits + 1)); fi
    done
    shopt -u nullglob
  else
    hits=""
  fi
  # The scan above only means something if it can find a known value. Look for a non-secret
  # one (the head SHA) in this process's own environment with the very same scan, so a scan
  # that fails inside the boundary (a missing tr or grep, an unreadable /proc) reads as blind.
  if ( : < "/proc/$$/environ" ) 2> /dev/null; then own_open=1; fi
  if [ -n "${PRT_HEAD_SHA:-}" ] && environ_has "/proc/$$/environ" "$PRT_HEAD_SHA"; then own_marker=1; fi
  for a in ${PRT_PROBE_ANCESTORS:-}; do
    p="${a%%:*}"; st="${a##*:}"
    for f in environ mem; do
      if ( : < "/proc/$p/$f" ) 2> /dev/null; then
        s="$(sed 's/^.*) //' "/proc/$p/stat" 2> /dev/null)"
        # shellcheck disable=SC2086 # the stat fields after the command name are plain words
        set -- $s
        # A pid number can belong to a neighbour inside a namespace: only the start time names the ancestor.
        if [ -z "$s" ] || [ "${20:-}" = "$st" ]; then
          if [ "$f" = environ ]; then anc_environ=$((anc_environ + 1)); else anc_mem=$((anc_mem + 1)); fi
        fi
      fi
    done
  done
  # Every descriptor above 2 this process holds, but the ones it opens itself: the shell's hold
  # on this script and the directory handle of this very listing.
  # Every entry is read, 0, 1 and 2 included: a listing that failed (the glob stays literal) or
  # came back short shows as fewer than the three standard descriptors, and then the count is
  # written empty, which the judge reads as unusable. It is never 0 for a listing that did not work.
  for p in "/proc/$$/fd"/*; do
    n="${p##*/}"
    [[ "$n" =~ ^[0-9]{1,9}$ ]] || continue
    case "$n" in 0|1|2) fd_std=$((fd_std + 1)); continue ;; esac
    [ -e "$p" ] || continue
    [ "$p" -ef "$self" ] && continue
    [ "$p" -ef "/proc/$$/fd" ] && continue
    fd_above2=$((fd_above2 + 1))
  done
  [ "$fd_std" -eq 3 ] || fd_above2=""
  # Who the stub is and which namespaces it sits in, as it sees them. Informational: the judge
  # does not read these. Its parent-death signal cannot be read from here: PR_GET_PDEATHSIG
  # answers only for the calling process, and a child starts with it cleared.
  pid_ns="$(readlink /proc/self/ns/pid 2> /dev/null)" || pid_ns=""
  nspid=""
  while IFS=$'\t' read -r key a; do
    if [ "$key" = "NSpid:" ]; then nspid="${a//$'\t'/\/}"; break; fi
  done 2> /dev/null < /proc/self/status || nspid=""
  if [ -z "$pid_ns" ] || [ -z "${PRT_PROBE_PARENT_PID_NS:-}" ]; then
    pid_ns_differs=unknown
  elif [ "$pid_ns" = "$PRT_PROBE_PARENT_PID_NS" ]; then pid_ns_differs=0
  else pid_ns_differs=1
  fi
  if [ "${PRT_PROBE_MOUNT:-skip}" = try ]; then
    # Both namespace names must have been read, and differ, before anything is mounted.
    own_ns="$(readlink /proc/self/ns/mnt 2> /dev/null)" || own_ns=""
    if [ -z "${PRT_PROBE_PARENT_MNT_NS:-}" ] || [ -z "$own_ns" ]; then
      mount_result=untried:mount-namespace-unreadable
    elif [ "$own_ns" = "$PRT_PROBE_PARENT_MNT_NS" ]; then
      mount_result=untried:shares-mount-namespace
    elif ! command -v mount > /dev/null 2>&1; then
      mount_result=untried:no-mount-command
    elif ! mnt="$(mktemp -d)"; then
      mount_result=untried:no-directory
    else
      msg="$(LC_ALL=C mount -t proc proc "$mnt" 2>&1)"; rc=$?
      if [ "$rc" -eq 0 ]; then
        mount_result=succeeded
        umount "$mnt" > /dev/null 2>&1 || true
      elif { [ "$rc" -eq 32 ] || [ "$rc" -eq 1 ]; } &&
        grep -qiE 'permission denied|not permitted|must be superuser|must be root' <<< "$msg"; then
        # Only mount's own refusal (status 1 or 32) is a denial; 126 and 127 mean it never ran.
        mount_result=denied
      else
        mount_result="failed:$rc"
      fi
      rmdir "$mnt" 2> /dev/null || true
    fi
  fi
  {
    echo "canary_hits=$hits"
    echo "ancestor_environ_open=$anc_environ"
    echo "ancestor_mem_open=$anc_mem"
    echo "fd_above_2=$fd_above2"
    echo "uid=$(id -u)"
    echo "cap_eff=$(sed -n 's/^CapEff:[[:space:]]*//p' /proc/self/status)"
    echo "cap_bnd=$(sed -n 's/^CapBnd:[[:space:]]*//p' /proc/self/status)"
    echo "no_new_privs=$(sed -n 's/^NoNewPrivs:[[:space:]]*//p' /proc/self/status)"
    echo "proc_mount=$mount_result"
    echo "canary_state=$canary_state"
    echo "nspid=${nspid:-unknown}"
    echo "pid_ns_differs=$pid_ns_differs"
    echo "user=$(id -un 2> /dev/null || echo unknown)"
    echo "groups=$(id -Gn 2> /dev/null | tr ' ' ',')"
    echo "own_environ_open=$own_open"
    echo "own_environ_marker=$own_marker"
    echo "own_env_names=$(compgen -e | sort | tr '\n' ' ')"
  } > "$PRT_PROBE_REPORT.tmp" && mv "$PRT_PROBE_REPORT.tmp" "$PRT_PROBE_REPORT"
  mkdir -p "$out"
  printf '{"assessments":[]}' > "$out/review.md"
  printf '{"format":"review-run-v1","outcome":"completed","identity":{"head":"%s","base":"%s","material_sha256":"%s","input_sha256":"%s"}}' \
    "$PRT_HEAD_SHA" "$PRT_REVIEW_BASE_SHA" "$PRT_REVIEW_MATERIAL_SHA256" "$(printf '%s' "$req" | sha256sum | cut -d' ' -f1)" > "$out/provider.json"
}

# ---------------------------------------------------------------------------------------
# judge BOUNDARY_REPORT CONTROL_REPORT — 0 pass, 1 leak, 3 inconclusive
# ---------------------------------------------------------------------------------------
probe_judge() {
  local b="$1" c="$2" k v uid
  local -a leaks=() unusable=()
  # The control first: it has to have run and shown the canary, or the boundary result is void.
  if [ ! -s "$c" ]; then
    unusable+=("the control report is missing or empty (the control did not run to its end)")
  else
    for k in canary_hits ancestor_environ_open; do
      v="$(get "$c" "$k")"
      if ! is_count "$v"; then unusable+=("control: $k is '${v:-empty}', not a number")
      elif [ "$v" -lt 1 ]; then unusable+=("control: $k is $v, so the probe cannot see what it looks for")
      fi
    done
  fi
  if [ ! -s "$b" ]; then
    unusable+=("the boundary report is missing or empty")
  else
    for k in canary_hits ancestor_environ_open ancestor_mem_open fd_above_2 uid; do
      v="$(get "$b" "$k")"
      if ! is_count "$v"; then unusable+=("boundary: $k is '${v:-empty}', not a number")
      elif [ "$k" != uid ] && [ "$v" -ne 0 ]; then leaks+=("boundary: $k is $v")
      fi
    done
    # A scan that found nothing counts only if it could have found something: inside the
    # boundary it must open its own environ and find a known value in it.
    v="$(get "$b" canary_state)"
    [ "$v" = ok ] || unusable+=("boundary: the canary was ${v:-not reported} in the stub, so nothing was looked for")
    for k in own_environ_open own_environ_marker; do
      v="$(get "$b" "$k")"
      if ! is_count "$v"; then unusable+=("boundary: $k is '${v:-empty}', not a number")
      elif [ "$v" -lt 1 ]; then unusable+=("boundary: $k is $v, so the scan inside the boundary may be blind")
      fi
    done
    uid="$(get "$b" uid)"
    v="$(get "$b" cap_eff)"
    if ! is_caps "$v"; then unusable+=("boundary: cap_eff is '${v:-empty}', not a capability set")
    elif [ "$v" != 0000000000000000 ]; then leaks+=("boundary: effective capabilities are $v")
    fi
    v="$(get "$b" cap_bnd)"
    if ! is_caps "$v"; then unusable+=("boundary: cap_bnd is '${v:-empty}', not a capability set")
    elif [ "$uid" = 0 ] && [ "$v" != 0000000000000000 ]; then leaks+=("boundary: root keeps the bounding set $v")
    fi
    v="$(get "$b" proc_mount)"
    case "$v" in
      denied) ;;
      succeeded) leaks+=("boundary: a procfs could be mounted") ;;
      *) unusable+=("boundary: the mount experiment gave '${v:-nothing}', not a denial") ;;
    esac
  fi
  for v in ${leaks[@]+"${leaks[@]}"}; do echo "LEAK: $v"; done
  for v in ${unusable[@]+"${unusable[@]}"}; do echo "UNUSABLE: $v"; done
  if [ "${#leaks[@]}" -gt 0 ]; then
    echo "RESULT: fail (the boundary leaks)"
    return 1
  fi
  if [ "${#unusable[@]}" -gt 0 ]; then
    echo "RESULT: inconclusive (no pass can be claimed)"
    return 3
  fi
  echo "RESULT: pass (canary unreadable from behind the boundary; the control read it)"
}

# ---------------------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------------------
probe_run() {
  # The re-exec carries the canary itself as its marker: a flag a caller could inherit (set to 1,
  # or to anything else) must not skip the swap and let a real token stand in as the canary. The
  # marker counts only when it has the canary's shape and is what the token variable holds.
  local canary_re='^probe-canary-[0-9a-f]{32}$'
  if ! [[ "${PRT_PROBE_REEXEC:-}" =~ $canary_re && "${PRT_GH_TOKEN:-}" = "${PRT_PROBE_REEXEC:-}" ]]; then
    # A real token in the caller's environment is never used or printed: the canary replaces it.
    local canary
    canary="probe-canary-$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
    if ! [[ "$canary" =~ $canary_re ]]; then
      echo "probe: no random canary could be made" >&2
      return 4
    fi
    exec env "PRT_GH_TOKEN=$canary" "GITHUB_TOKEN=$canary" "GH_TOKEN=$canary" "PRT_PROBE_REEXEC=$canary" bash "$self" "$@"
  fi
  local here work q stat k call_rc=0 failure line
  local -a ancestors=() fields=()
  here="$(dirname "$self")"
  # shellcheck source=/dev/null
  source "$here/lib/prt/model.sh" || { echo "probe: cannot load the orchestrator's model functions" >&2; return 4; }

  work="$(mktemp -d)" || { echo "probe: no temporary directory" >&2; return 4; }
  # shellcheck disable=SC2064 # expand now: $work is function-local and gone when the trap fires
  trap "rm -rf '$work'" EXIT
  umask 077
  printf '%s' "$PRT_GH_TOKEN" > "$work/canary" || { echo "probe: cannot write the canary file" >&2; return 4; }

  echo "lane: kernel=$(uname -sr) uid=$(id -u) os=$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2> /dev/null | tr -d '"')"
  echo "lane: $(grep -E '^(Seccomp|NoNewPrivs):' /proc/self/status | tr '\n\t' '  ')"
  echo "lane: orchestrator user=$(id -un 2> /dev/null || echo n/a) groups=$(id -Gn 2> /dev/null | tr ' ' ',')"
  for k in kernel/yama/ptrace_scope kernel/apparmor_restrict_unprivileged_userns kernel/unprivileged_userns_clone \
    kernel/unprivileged_userns_apparmor_policy user/max_user_namespaces user/max_pid_namespaces; do
    echo "lane: $k=$(cat "/proc/sys/$k" 2> /dev/null || echo n/a)"
  done
  # Which step of the default boundary this lane refuses, and what it says. Each attempt runs
  # `true` and nothing else; none needs a capability or leaves anything behind.
  for k in "--user --map-current-user" "--user --map-current-user --pid --fork" \
    "--user --map-current-user --pid --fork --mount-proc"; do
    # shellcheck disable=SC2086 # the option words are meant to split
    if q="$(unshare $k true 2>&1)"; then
      echo "lane: unshare $k: ok"
    else
      echo "lane: unshare $k: failed rc=$? ${q:-no message}"
    fi
  done

  # The pids from this process up to pid 1, each as pid:start-time, as the boundary check names them.
  q="$BASHPID"
  while [ "$q" -ge 1 ]; do
    [ "${#ancestors[@]}" -lt 256 ] || { echo "probe: ancestor chain too long" >&2; return 4; }
    stat="$(< "/proc/$q/stat")" || { echo "probe: cannot read /proc/$q/stat" >&2; return 4; }
    read -ra fields <<< "${stat##*) }"
    ancestors+=("$q:${fields[19]}")
    q="${fields[1]}"
  done

  # The stand-in for review-run: this script's stub mode.
  if ! { printf '#!/bin/sh\nexec bash %q stub "$@"\n' "$self" > "$work/review-run" && chmod 755 "$work/review-run"; }; then
    echo "probe: cannot write the stand-in runner" >&2
    return 4
  fi

  export PRT_HEAD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  export PRT_REVIEW_BASE_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  export PRT_REVIEW_MATERIAL_SHA256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
  export PRT_PROBE_CANARY_FILE="$work/canary"
  export PRT_PROBE_ANCESTORS="${ancestors[*]}"
  PRT_PROBE_PARENT_MNT_NS="$(readlink /proc/self/ns/mnt 2> /dev/null)" || PRT_PROBE_PARENT_MNT_NS=""
  if [ -z "$PRT_PROBE_PARENT_MNT_NS" ]; then
    echo "probe: cannot read this process's mount namespace" >&2
    return 4
  fi
  export PRT_PROBE_PARENT_MNT_NS
  PRT_PROBE_PARENT_PID_NS="$(readlink /proc/self/ns/pid 2> /dev/null)" || PRT_PROBE_PARENT_PID_NS=""
  export PRT_PROBE_PARENT_PID_NS
  export PRT_ASSESS_RUNNER="$work/review-run"
  export PRT_ASSESS_RUNNER_BACKEND=probe
  export PRT_ASSESS_RUNNER_ROOT="$PWD"
  export PRT_ASSESS_RUNNER_SECONDS=60
  export PRT_ASSESS_RUNNER_ENV="PRT_PROBE_REPORT PRT_PROBE_CANARY_FILE PRT_PROBE_ANCESTORS PRT_PROBE_MOUNT PRT_PROBE_PARENT_MNT_NS PRT_PROBE_PARENT_PID_NS PRT_HEAD_SHA PRT_REVIEW_BASE_SHA PRT_REVIEW_MATERIAL_SHA256"
  export PRT_LAST_MODEL_FAILURE_FILE="$work/failure"
  unset PRT_ASSESS_RUNNER_BOUNDARY PRT_ASSESS_RUNNER_BOUNDARY_CMD

  # Boundary: the production call. Its own per-call check runs first. The mount experiment
  # runs here only, in the namespace the boundary gives the stub.
  export PRT_PROBE_REPORT="$work/report.boundary"
  export PRT_PROBE_MOUNT=try
  _prt_call_runner "request for the boundary probe" > "$work/answer" 2> "$work/call.stderr" || call_rc=$?
  failure="$(cat "$work/failure" 2> /dev/null || true)"
  if [ "$call_rc" -ne 0 ] || [ ! -s "$work/report.boundary" ]; then
    echo "boundary: call failed rc=$call_rc reason=${failure:-none}"
    # The orchestrator's own words, with every absolute path made anonymous: a message can name
    # its temporary directory, which is nothing this run's log should carry.
    # A sed that fails prints nothing, which errs on the side of saying less.
    while IFS= read -r line; do echo "boundary: $line"; done \
      < <(sed -E 's#/[^[:space:]:"'"'"')]+#<path>#g' "$work/call.stderr" 2> /dev/null)
    case "$failure" in
      runner-boundary)
        echo "RESULT: not-established (the default boundary cannot be set up or fails its own check on this lane)"
        return 2 ;;
      runner-*|provenance-mismatch)
        # The boundary was established and the stub ran (or should have): the call failed after it.
        echo "RESULT: fail (the call failed after the boundary was established: $failure)"
        return 1 ;;
      "")
        if [ "$call_rc" -eq 0 ]; then
          echo "RESULT: inconclusive (the call succeeded but the stub left no report)"
          return 3
        fi
        echo "RESULT: setup-failed (the call failed with no reason recorded)"
        return 4 ;;
      *)
        # backend-config, deadline-exhausted, local-tempdir: refused before or around the boundary,
        # nothing here says the boundary was established. Not a verdict on it.
        echo "RESULT: setup-failed (the call was refused before the stub could run: $failure)"
        return 4 ;;
    esac
  fi

  # Control: same stub, same scrub and descriptor closing, no boundary, no mount experiment.
  export PRT_PROBE_REPORT="$work/report.control"
  export PRT_PROBE_MOUNT=skip
  if ! _prt_runner_env_build; then
    echo "RESULT: inconclusive (control environment: $PRT_RUNNER_ENV_ERROR)"
    return 3
  fi
  (
    for fd_path in /proc/self/fd/*; do
      fd="${fd_path##*/}"
      if [ "$fd" -gt 2 ] 2> /dev/null; then eval "exec $fd>&-"; fi
    done
    exec env -i "${PRT_RUNNER_ENV_ARGS[@]}" "$PRT_ASSESS_RUNNER" --out "$work/control-out" --backend probe \
      < /dev/null > /dev/null 2>&1
  ) || echo "control: the stub exited non-zero"

  for k in boundary control; do
    echo "$k:"
    if [ -s "$work/report.$k" ]; then
      while IFS= read -r line; do echo "  $line"; done < "$work/report.$k"
    else
      echo "  (no report)"
    fi
  done
  probe_judge "$work/report.boundary" "$work/report.control"
}

case "${1:-run}" in
  judge) shift; probe_judge "${1:-}" "${2:-}" ;;
  stub) shift; probe_stub "$@" ;;
  run) probe_run "$@" ;;
  *) echo "usage: $0 [run | judge BOUNDARY_REPORT CONTROL_REPORT]" >&2; exit 64 ;;
esac
