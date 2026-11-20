#!/usr/bin/env bash
# release-notes-contract-test.sh — Release / Publish refuses to publish a release whose notes
# GoReleaser would drop (go-kure/.github#470).
#
# GoReleaser reads `--release-notes FILE` only inside its changelog pipe, and it skips that whole
# pipe when the caller's .goreleaser.yml sets `changelog.disable: true`. The notes step succeeded,
# the file was never read, and the release body was a single newline. scripts/release/
# check-release-notes.sh refuses that before anything is created on GitHub; the same check refuses
# a notes file that is missing or holds only whitespace.
#
# The first cases run the script on temporary configs and notes, including the six file names
# GoReleaser looks for, in its order. The last three read release-publish.yml: the check runs
# after the notes are written and before GoReleaser, and the script is copied out of the sparse
# checkout that the git-cliff step deletes.
#
# What this cannot prove: that GitHub shows the body. The contract is read from files, so the only
# end-to-end proof is the first real release after a caller drops `changelog.disable`.
#
# Usage: release-notes-contract-test.sh [REPO_ROOT]

set -uo pipefail # not -e: report every case, not just the first failure

ROOT="${1:-.}"
ROOT="$(cd "$ROOT" && pwd)"
CHECK="$ROOT/scripts/release/check-release-notes.sh"
WF="$ROOT/.github/workflows/release-publish.yml"

failures=0
pass_count=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

printf '## [0.0.1] - 2026-11-20\n\n### Features\n\n- First thing\n' >"$tmp/notes.md"
: >"$tmp/empty.md"
printf ' \n\t\n\n' >"$tmp/blank.md"

# cfg NAME BODY — write a .goreleaser.yml body to $tmp/NAME.
cfg() {
  printf '%s\n' "$2" >"$tmp/$1"
}

cfg disable-true $'version: 2\nproject_name: x\nchangelog:\n  disable: true\nrelease:\n  draft: false'
cfg disable-true-comment $'version: 2\nchangelog:\n  # we use git-cliff\n  disable: true # skip\n'
cfg disable-true-quoted $'version: 2\nchangelog:\n  disable: "true"\n'
cfg disable-true-inline $'version: 2\nchangelog: {disable: true}\n'
cfg disable-template $'version: 2\nchangelog:\n  disable: "{{ .Env.NO_CHANGELOG }}"\n'
cfg absent $'version: 2\nproject_name: x\nrelease:\n  draft: false'
cfg disable-false $'version: 2\nchangelog:\n  disable: false\n  sort: asc\n'
cfg disable-false-quoted $'version: 2\nchangelog:\n  disable: "false"\n'
# Quoted keys are the same YAML keys. GoReleaser (v2.20.3, tmpl.Bool) trims and lower-cases the
# value and only "true" disables the step: "", "false", "yes" and "0" leave it on.
cfg quoted-key-true $'version: 2\nchangelog:\n  "disable": true\n'
cfg single-quoted-key-true $'version: 2\nchangelog:\n  \'disable\': \'true\'\n'
cfg quoted-top-key-true $'version: 2\n"changelog":\n  disable: true\n'
cfg quoted-inline-key-true $'version: 2\n\'changelog\': {"disable": true}\n'
cfg disable-true-spaced $'version: 2\nchangelog:\n  disable: " TRUE "\n'
cfg disable-empty-string $'version: 2\nchangelog:\n  disable: ""\n'
cfg disable-yes $'version: 2\nchangelog:\n  disable: yes\n'
cfg disable-no-value $'version: 2\nchangelog:\n  disable:\n  sort: asc\n'
# `disable: true` under another key is not the changelog's.
cfg other-key-true $'version: 2\nchangelog:\n  sort: asc\nsnapshot:\n  disable: true\nbrews:\n  - disable: true\n'
cfg changelog-after-true $'version: 2\nsnapshot:\n  disable: true\nchangelog:\n  disable: true\n'

# run NAME WANT_RC WANT_TEXT -- ARGS... — the check must exit WANT_RC; with WANT_TEXT it must also
# print that text (stdout and stderr together).
run() {
  local name="$1" want_rc="$2" want="$3" out rc
  shift 4
  out="$(bash "$CHECK" "$@" 2>&1)"
  rc=$?
  if [ "$rc" -ne "$want_rc" ]; then
    echo "FAIL: $name: expected exit $want_rc, got $rc:"
    echo "$out"
    failures=$((failures + 1))
  elif [ -n "$want" ] && ! grep -qF -- "$want" <<<"$out"; then
    echo "FAIL: $name: expected the text '$want', got:"
    echo "$out"
    failures=$((failures + 1))
  else
    pass_count=$((pass_count + 1))
    echo "PASS  $name"
  fi
}

# 1-4: the failure the issue reports, in every spelling of "true".
run "changelog.disable true" 1 "changelog.disable" -- "$tmp/notes.md" "$tmp/disable-true"
run "changelog.disable true, comments around it" 1 "changelog.disable" -- "$tmp/notes.md" "$tmp/disable-true-comment"
run "changelog.disable \"true\" quoted" 1 "changelog.disable" -- "$tmp/notes.md" "$tmp/disable-true-quoted"
run "changelog as an inline map with disable true" 1 "changelog.disable" -- "$tmp/notes.md" "$tmp/disable-true-inline"
run "quoted key \"disable\"" 1 "changelog.disable" -- "$tmp/notes.md" "$tmp/quoted-key-true"
run "single-quoted key and value" 1 "changelog.disable" -- "$tmp/notes.md" "$tmp/single-quoted-key-true"
run "quoted top-level key \"changelog\"" 1 "changelog.disable" -- "$tmp/notes.md" "$tmp/quoted-top-key-true"
run "quoted keys in an inline map" 1 "changelog.disable" -- "$tmp/notes.md" "$tmp/quoted-inline-key-true"
run "changelog.disable \" TRUE \" (GoReleaser trims and lower-cases)" 1 "changelog.disable" -- "$tmp/notes.md" "$tmp/disable-true-spaced"
run "changelog.disable empty string (GoReleaser reads false)" 0 "" -- "$tmp/notes.md" "$tmp/disable-empty-string"
run "changelog.disable yes (GoReleaser reads false)" 0 "" -- "$tmp/notes.md" "$tmp/disable-yes"
run "changelog.disable with no value" 0 "" -- "$tmp/notes.md" "$tmp/disable-no-value"
# 5: a template cannot be read before the run, so the check refuses it.
run "changelog.disable as a template" 1 "cannot be read" -- "$tmp/notes.md" "$tmp/disable-template"
# 6-9: configs that keep the changelog pipe, so --release-notes is read.
run "no changelog block" 0 "" -- "$tmp/notes.md" "$tmp/absent"
run "changelog.disable false" 0 "" -- "$tmp/notes.md" "$tmp/disable-false"
run "changelog.disable \"false\" quoted" 0 "" -- "$tmp/notes.md" "$tmp/disable-false-quoted"
run "disable true under other keys only" 0 "" -- "$tmp/notes.md" "$tmp/other-key-true"
# 10: the changelog block after another block that has its own disable.
run "changelog block after another disable" 1 "changelog.disable" -- "$tmp/notes.md" "$tmp/changelog-after-true"
# 11-13: the notes file.
run "empty notes" 1 "empty" -- "$tmp/empty.md" "$tmp/absent"
run "whitespace-only notes" 1 "empty" -- "$tmp/blank.md" "$tmp/absent"
run "missing notes file" 1 "missing" -- "$tmp/nonexistent.md" "$tmp/absent"
# 14: both faults reported in one run, so a fix of one does not hide the other.
out="$(bash "$CHECK" "$tmp/empty.md" "$tmp/disable-true" 2>&1)"
if grep -qF -- "changelog.disable" <<<"$out" && grep -qF -- "empty" <<<"$out"; then
  pass_count=$((pass_count + 1))
  echo "PASS  both faults named in one run"
else
  echo "FAIL: both faults named in one run, got:"
  echo "$out"
  failures=$((failures + 1))
fi
# 15: a config that is not there is a failure to read, never a pass.
run "missing config file" 1 "missing" -- "$tmp/notes.md" "$tmp/nonexistent.yml"
# 16-22: no config argument means the file GoReleaser itself picks (cmd/config.go, v2.20.3): the
# first existing of the six names, in its order. in_dir NAME WANT_RC FILE... — a directory that
# holds the listed files (the first one carrying changelog.disable: true, the others a clean
# config), checked with no config argument.
in_dir() {
  local name="$1" want_rc="$2" first=1 f d="$tmp/dir-$RANDOM" out rc
  shift 2
  mkdir -p "$d"
  for f in "$@"; do
    mkdir -p "$d/$(dirname "$f")"
    if [ "$first" -eq 1 ] && [ "$want_rc" -eq 1 ]; then cp "$tmp/disable-true" "$d/$f"; else cp "$tmp/absent" "$d/$f"; fi
    first=0
  done
  out="$(cd "$d" && bash "$CHECK" "$tmp/notes.md" 2>&1)"
  rc=$?
  if [ "$rc" -eq "$want_rc" ]; then
    pass_count=$((pass_count + 1))
    echo "PASS  $name"
  else
    echo "FAIL: $name: expected exit $want_rc, got $rc:"
    echo "$out"
    failures=$((failures + 1))
  fi
}
in_dir "default config .goreleaser.yml is found" 1 .goreleaser.yml
in_dir "default config .goreleaser.yaml is found" 1 .goreleaser.yaml
in_dir "default config .config/goreleaser.yml is found" 1 .config/goreleaser.yml
in_dir "default config .config/goreleaser.yaml is found" 1 .config/goreleaser.yaml
in_dir "default config goreleaser.yml is found" 1 goreleaser.yml
in_dir "default config goreleaser.yaml is found" 1 goreleaser.yaml
# The first name in GoReleaser's order wins, so a disabled changelog in a later file is not read.
in_dir "the first name in GoReleaser's order wins over a later one" 1 .config/goreleaser.yml .goreleaser.yml
in_dir ".goreleaser.yml wins over .goreleaser.yaml" 1 .goreleaser.yml .goreleaser.yaml
# The reverse: a clean config that GoReleaser reads first hides a later disabled one, as for GoReleaser.
mkdir -p "$tmp/shadow"
cp "$tmp/absent" "$tmp/shadow/.goreleaser.yml"
cp "$tmp/disable-true" "$tmp/shadow/goreleaser.yml"
if (cd "$tmp/shadow" && bash "$CHECK" "$tmp/notes.md" >/dev/null 2>&1); then
  pass_count=$((pass_count + 1))
  echo "PASS  a clean config read first is the one that counts"
else
  echo "FAIL: a clean config read first is the one that counts"
  failures=$((failures + 1))
fi
mkdir -p "$tmp/none"
out="$(cd "$tmp/none" && bash "$CHECK" "$tmp/notes.md" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ]; then
  pass_count=$((pass_count + 1))
  echo "PASS  no config file at all: GoReleaser's defaults keep the changelog pipe"
else
  echo "FAIL: no config file at all, exit $rc:"
  echo "$out"
  failures=$((failures + 1))
fi

# 18-20: the workflow wires it. step_line PATTERN — the line of the first step name matching it.
step_line() {
  grep -nE -- "^      - name: $1" "$WF" | head -n 1 | cut -d: -f1
}
extract="$(step_line 'Extract release notes$')"
check="$(step_line 'Check the release notes reach GoReleaser$')"
goreleaser="$(step_line 'Run GoReleaser$')"
if [ -n "$extract" ] && [ -n "$check" ] && [ -n "$goreleaser" ] &&
  [ "$extract" -lt "$check" ] && [ "$check" -lt "$goreleaser" ]; then
  pass_count=$((pass_count + 1))
  echo "PASS  the check runs after the notes are written and before GoReleaser"
else
  echo "FAIL: the check runs after the notes are written and before GoReleaser (lines: extract=$extract check=$check goreleaser=$goreleaser)"
  failures=$((failures + 1))
fi
if [ -n "$check" ] && sed -n "${check},$((check + 14))p" "$WF" | grep -qF 'check-release-notes.sh'; then
  pass_count=$((pass_count + 1))
  echo "PASS  the check step runs check-release-notes.sh"
else
  echo "FAIL: the check step does not run check-release-notes.sh"
  failures=$((failures + 1))
fi
# The git-cliff step deletes the sparse checkout the script comes from, so a copy must be made first.
cp_line="$(grep -nF 'cp .git-cliff-installer/scripts/release/check-release-notes.sh' "$WF" | head -n 1 | cut -d: -f1)"
rm_line="$(grep -nF 'rm -rf .git-cliff-installer' "$WF" | head -n 1 | cut -d: -f1)"
if [ -n "$cp_line" ] && [ -n "$rm_line" ] && [ "$cp_line" -lt "$rm_line" ]; then
  pass_count=$((pass_count + 1))
  echo "PASS  the script is copied out before the installer checkout is deleted"
else
  echo "FAIL: the script is copied out before the installer checkout is deleted (cp=$cp_line rm=$rm_line)"
  failures=$((failures + 1))
fi

if [ "$failures" -eq 0 ]; then
  echo "release-notes-contract-test: OK ($pass_count cases)"
  exit 0
fi
echo "release-notes-contract-test: FAILED ($failures failed, $pass_count passed)"
exit 1
