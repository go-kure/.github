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
# answer, so no pass can be claimed; 4 the probe could not set itself up.
set -uo pipefail

self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# ---------------------------------------------------------------------------------------
# report files: KEY=VALUE lines
# ---------------------------------------------------------------------------------------
get() { sed -n "s/^$2=//p" "$1" 2> /dev/null | head -1; }
is_count() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }
is_caps() { [[ "${1:-}" =~ ^[0-9a-f]{16}$ ]]; }

# ---------------------------------------------------------------------------------------
# stub: what a runner could reach, written to $PRT_PROBE_REPORT, then a clean answer
# ---------------------------------------------------------------------------------------
probe_stub() {
  local out="" req canary a p st f s n e mnt msg rc
  local anc_environ=0 anc_mem=0 hits=0 visible=0 fd_above2=0 mount_result=skipped
  while [ $# -gt 0 ]; do
    case "$1" in
      --out) out="$2"; shift 2 ;;
      --) shift; break ;;
      --backend|--root|--base|--seconds|--sandbox) shift 2 ;;
      *) shift ;;
    esac
  done
  req="$(cat)"
  canary="$(cat "$PRT_PROBE_CANARY_FILE")"
  for e in /proc/[0-9]*/environ; do
    visible=$((visible + 1))
    if { tr '\0' '\n' < "$e"; } 2> /dev/null | grep -qF -- "$canary"; then hits=$((hits + 1)); fi
  done
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
  for p in "/proc/$$/fd"/*; do
    n="${p##*/}"
    [ "$n" -gt 2 ] 2> /dev/null || continue
    [ -e "$p" ] || continue
    [ "$p" -ef "$self" ] && continue
    [ "$p" -ef "/proc/$$/fd" ] && continue
    fd_above2=$((fd_above2 + 1))
  done
  if [ "${PRT_PROBE_MOUNT:-skip}" = try ]; then
    if [ -z "${PRT_PROBE_PARENT_MNT_NS:-}" ] || [ "$(readlink /proc/self/ns/mnt)" = "$PRT_PROBE_PARENT_MNT_NS" ]; then
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
      elif grep -qiE 'permission denied|not permitted|must be superuser|must be root' <<< "$msg"; then
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
    echo "pids_visible=$visible"
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
  if [ -z "${PRT_PROBE_REEXEC:-}" ]; then
    # A real token in the caller's environment is never used or printed: the canary replaces it.
    local canary
    canary="probe-canary-$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
    exec env "PRT_GH_TOKEN=$canary" "GITHUB_TOKEN=$canary" "GH_TOKEN=$canary" PRT_PROBE_REEXEC=1 bash "$self" "$@"
  fi
  local here work q stat k call_rc=0 failure line
  local -a ancestors=() fields=()
  here="$(dirname "$self")"
  # shellcheck source=/dev/null
  source "$here/lib/prt/model.sh"

  work="$(mktemp -d)" || { echo "probe: no temporary directory" >&2; return 4; }
  # shellcheck disable=SC2064 # expand now: $work is function-local and gone when the trap fires
  trap "rm -rf '$work'" EXIT
  umask 077
  printf '%s' "$PRT_GH_TOKEN" > "$work/canary"

  echo "lane: kernel=$(uname -sr) uid=$(id -u) os=$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2> /dev/null | tr -d '"')"
  echo "lane: $(grep -E '^(Seccomp|NoNewPrivs):' /proc/self/status | tr '\n\t' '  ')"
  for k in kernel/yama/ptrace_scope kernel/apparmor_restrict_unprivileged_userns user/max_user_namespaces; do
    echo "lane: $k=$(cat "/proc/sys/$k" 2> /dev/null || echo n/a)"
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
  printf '#!/bin/sh\nexec bash %q stub "$@"\n' "$self" > "$work/review-run"
  chmod 755 "$work/review-run"

  export PRT_HEAD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  export PRT_REVIEW_BASE_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  export PRT_REVIEW_MATERIAL_SHA256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
  export PRT_PROBE_CANARY_FILE="$work/canary"
  export PRT_PROBE_ANCESTORS="${ancestors[*]}"
  PRT_PROBE_PARENT_MNT_NS="$(readlink /proc/self/ns/mnt)"
  export PRT_PROBE_PARENT_MNT_NS
  export PRT_ASSESS_RUNNER="$work/review-run"
  export PRT_ASSESS_RUNNER_BACKEND=probe
  export PRT_ASSESS_RUNNER_ROOT="$PWD"
  export PRT_ASSESS_RUNNER_SECONDS=60
  export PRT_ASSESS_RUNNER_ENV="PRT_PROBE_REPORT PRT_PROBE_CANARY_FILE PRT_PROBE_ANCESTORS PRT_PROBE_MOUNT PRT_PROBE_PARENT_MNT_NS PRT_HEAD_SHA PRT_REVIEW_BASE_SHA PRT_REVIEW_MATERIAL_SHA256"
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
    while IFS= read -r line; do echo "boundary: $line"; done < "$work/call.stderr"
    if [ "$failure" = runner-boundary ]; then
      echo "RESULT: not-established (the default boundary cannot be set up or fails its own check on this lane)"
      return 2
    fi
    echo "RESULT: fail (the call failed after the boundary was established: ${failure:-no reason recorded})"
    return 1
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
