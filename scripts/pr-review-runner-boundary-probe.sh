#!/usr/bin/env bash
# pr-review-runner-boundary-probe.sh — acceptance run for the runner's process boundary
# (PRT_ASSESS_BACKEND=runner, see docs/pr-review-threads.md "Process boundary").
#
# It shows, on the host it runs on, whether a runner started the way the orchestrator
# starts it can read the posting token. It uses a made-up canary in place of the token and a
# stub in place of the real runner: no secret, no model call, no forge access, and it reads
# /proc only. The canary is placed in this script's own environment at exec time, so it sits
# where the posting token sits for the orchestrator, in an ancestor's /proc/<pid>/environ.
#
# Two probes run, both through the same environment scrub and descriptor closing:
#   boundary  the production call, _prt_call_runner (default boundary, checked, bounded)
#   control   the same stub with `env -i` only, no boundary
# The control must see the canary. If it does not, the probe cannot see and the boundary
# result means nothing.
#
# Exit codes: 0 the boundary holds and the control saw the canary; 1 the boundary leaks (or the
# call failed after the boundary was established); 2 the boundary cannot be established here;
# 3 the control did not see the canary (the probe is blind).
set -uo pipefail

if [ -z "${PRT_PROBE_REEXEC:-}" ]; then
  # A real token in the caller's environment is never used or printed: the canary replaces it.
  canary="probe-canary-$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  exec env "PRT_GH_TOKEN=$canary" "GITHUB_TOKEN=$canary" "GH_TOKEN=$canary" PRT_PROBE_REEXEC=1 bash "$0" "$@"
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/prt/model.sh
source "$here/lib/prt/model.sh"

work="$(mktemp -d)" || { echo "probe: no temporary directory" >&2; exit 4; }
trap 'rm -rf "$work"' EXIT
umask 077
printf '%s' "$PRT_GH_TOKEN" > "$work/canary"

echo "lane: kernel=$(uname -sr) uid=$(id -u) os=$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2> /dev/null | tr -d '"')"
echo "lane: $(grep -E '^(Seccomp|NoNewPrivs):' /proc/self/status | tr '\n\t' '  ')"
for k in kernel/yama/ptrace_scope kernel/apparmor_restrict_unprivileged_userns user/max_user_namespaces; do
  echo "lane: $k=$(cat "/proc/sys/$k" 2> /dev/null || echo n/a)"
done

# The pids from this process up to pid 1, each as pid:start-time, as the boundary check names them.
ancestors=()
q="$BASHPID"
while [ "$q" -ge 1 ]; do
  [ "${#ancestors[@]}" -lt 256 ] || { echo "probe: ancestor chain too long" >&2; exit 4; }
  stat="$(< "/proc/$q/stat")" || { echo "probe: cannot read /proc/$q/stat" >&2; exit 4; }
  read -ra fields <<< "${stat##*) }"
  ancestors+=("$q:${fields[19]}")
  q="${fields[1]}"
done

# The stand-in for review-run: probes what it can reach, writes a report, answers like a clean run.
cat > "$work/review-run" << 'STUB'
#!/usr/bin/env bash
set -u
out=""
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
anc_environ=0; anc_mem=0; hits=0; visible=0; fd_above2=0
for e in /proc/[0-9]*/environ; do
  visible=$((visible + 1))
  if { tr '\0' '\n' < "$e"; } 2> /dev/null | grep -qF -- "$canary"; then hits=$((hits + 1)); fi
done
for a in $PRT_PROBE_ANCESTORS; do
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
# Tested by number from this shell's own pid: a glob of /proc/self/fd would list its own
# directory handle, and 255 is the shell's hold on this script.
for ((n = 3; n < 255; n++)); do
  if [ -e "/proc/$$/fd/$n" ]; then fd_above2=$((fd_above2 + 1)); fi
done
mnt="$(mktemp -d)"
mount -t proc proc "$mnt" > /dev/null 2>&1; mount_rc=$?
rmdir "$mnt" 2> /dev/null
{
  echo "canary_hits=$hits"
  echo "ancestor_environ_open=$anc_environ"
  echo "ancestor_mem_open=$anc_mem"
  echo "fd_above_2=$fd_above2"
  echo "cap_eff=$(sed -n 's/^CapEff:[[:space:]]*//p' /proc/self/status)"
  echo "cap_bnd=$(sed -n 's/^CapBnd:[[:space:]]*//p' /proc/self/status)"
  echo "no_new_privs=$(sed -n 's/^NoNewPrivs:[[:space:]]*//p' /proc/self/status)"
  echo "proc_mount_rc=$mount_rc"
  echo "pids_visible=$visible"
  echo "own_env_names=$(compgen -e | sort | tr '\n' ' ')"
} > "$PRT_PROBE_REPORT"
mkdir -p "$out"
printf '{"assessments":[]}' > "$out/review.md"
in_sha="$(printf '%s' "$req" | sha256sum | cut -d' ' -f1)"
printf '{"format":"review-run-v1","outcome":"completed","identity":{"head":"%s","base":"%s","material_sha256":"%s","input_sha256":"%s"}}' \
  "$PRT_HEAD_SHA" "$PRT_REVIEW_BASE_SHA" "$PRT_REVIEW_MATERIAL_SHA256" "$in_sha" > "$out/provider.json"
STUB
chmod 755 "$work/review-run"

export PRT_HEAD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export PRT_REVIEW_BASE_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
export PRT_REVIEW_MATERIAL_SHA256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
export PRT_PROBE_CANARY_FILE="$work/canary"
export PRT_PROBE_ANCESTORS="${ancestors[*]}"
export PRT_ASSESS_RUNNER="$work/review-run"
export PRT_ASSESS_RUNNER_BACKEND=probe
export PRT_ASSESS_RUNNER_ROOT="$PWD"
export PRT_ASSESS_RUNNER_SECONDS=60
export PRT_ASSESS_RUNNER_ENV="PRT_PROBE_REPORT PRT_PROBE_CANARY_FILE PRT_PROBE_ANCESTORS PRT_HEAD_SHA PRT_REVIEW_BASE_SHA PRT_REVIEW_MATERIAL_SHA256"
export PRT_LAST_MODEL_FAILURE_FILE="$work/failure"
unset PRT_ASSESS_RUNNER_BOUNDARY PRT_ASSESS_RUNNER_BOUNDARY_CMD

# Boundary: the production call. Its own per-call check runs first.
export PRT_PROBE_REPORT="$work/report.boundary"
call_rc=0
_prt_call_runner "request for the boundary probe" > "$work/answer" 2> "$work/call.stderr" || call_rc=$?
failure="$(cat "$work/failure" 2> /dev/null || true)"
if [ "$call_rc" -ne 0 ] || [ ! -s "$work/report.boundary" ]; then
  echo "boundary: call failed rc=$call_rc reason=${failure:-none}"
  sed 's/^/boundary: /' "$work/call.stderr"
  if [ "$failure" = runner-boundary ]; then
    echo "RESULT: not-established (the default boundary cannot be set up or fails its own check on this lane)"
    exit 2
  fi
  echo "RESULT: fail (the call failed after the boundary was established: $failure)"
  exit 1
fi

# Control: same stub, same scrub and descriptor closing, no boundary.
export PRT_PROBE_REPORT="$work/report.control"
_prt_runner_env_build || { echo "RESULT: fail (control environment: $PRT_RUNNER_ENV_ERROR)"; exit 1; }
(
  for fd_path in /proc/self/fd/*; do
    fd="${fd_path##*/}"
    if [ "$fd" -gt 2 ] 2> /dev/null; then eval "exec $fd>&-"; fi
  done
  exec env -i "${PRT_RUNNER_ENV_ARGS[@]}" "$PRT_ASSESS_RUNNER" --out "$work/control-out" --backend probe \
    < /dev/null > /dev/null 2>&1
) || true

get() { sed -n "s/^$2=//p" "$work/report.$1" 2> /dev/null | head -1; }
for side in boundary control; do
  echo "$side:"
  sed 's/^/  /' "$work/report.$side" 2> /dev/null || echo "  (no report)"
done

# judge SIDE — one line per way that side's report shows the token or the host reachable.
# Used on both reports: the control has to come out as leaking, or the judge and probe are blind.
judge() {
  [ "$(get "$1" canary_hits)" = 0 ] || echo "canary found in a /proc/<pid>/environ"
  [ "$(get "$1" ancestor_environ_open)" = 0 ] || echo "an ancestor's environ can be opened"
  [ "$(get "$1" ancestor_mem_open)" = 0 ] || echo "an ancestor's mem can be opened"
  [ "$(get "$1" fd_above_2)" = 0 ] || echo "a descriptor above 2 is open"
  [ "$(get "$1" cap_eff)" = 0000000000000000 ] || echo "effective capabilities are not empty"
  [ "$(get "$1" cap_bnd)" = 0000000000000000 ] || [ "$(id -u)" != 0 ] || echo "bounding set is not empty for root"
  [ "$(get "$1" proc_mount_rc)" != 0 ] || echo "a procfs can be mounted"
}

control_leaks="$(judge control)"
if ! grep -q 'canary found' <<< "$control_leaks" || ! grep -q "ancestor's environ" <<< "$control_leaks"; then
  echo "RESULT: blind (the control did not show the canary through an ancestor, so the probe shows nothing)"
  exit 3
fi
boundary_leaks="$(judge boundary)"
if [ -n "$boundary_leaks" ]; then
  sed 's/^/boundary leak: /' <<< "$boundary_leaks"
  echo "RESULT: fail"
  exit 1
fi
echo "RESULT: pass (canary unreadable from behind the boundary; the control read it)"
