#!/usr/bin/env bash
# release-checkout-pin-test.sh — the git-cliff installer finds its version pin in
# the checkout the release workflows make.
#
# release.yml and release-publish.yml check this repository out at
# job.workflow_sha with `sparse-checkout: scripts/release`, and actions/checkout
# runs that in cone mode by default. Cone mode also checks out every file in the
# repository root, so mise.toml, which holds GIT_CLIFF_VERSION, arrives beside
# scripts/release. install-git-cliff.sh reads the pin from the mise.toml two
# directories above itself (go-kure/.github#390). If cone mode ever stopped
# carrying root files, or the workflows changed their checkout, every release
# would fail at the install step, so this test makes the same checkout and runs
# the installer with no version argument.
#
# The installer then fails at its download, by design: a stub curl records the
# URL it was asked for and fails, and the URL must name the version in mise.toml.
# Nothing is downloaded or installed.
#
# Usage: release-checkout-pin-test.sh [REPO_ROOT]
# Requires: git, gpg (the installer checks for it before downloading).
# Reads the committed HEAD of REPO_ROOT, because that is what a workflow checks out.

set -uo pipefail

ROOT="${1:-.}"
ROOT="$(cd "$ROOT" && pwd)"

if ! git -C "$ROOT" rev-parse --verify HEAD >/dev/null 2>&1; then
  echo "SKIP: $ROOT is not a git checkout with a commit, so the workflows' sparse checkout cannot be reproduced" >&2
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

failures=0
pass_count=0
check() {
  if [ "$2" = ok ]; then
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $1" >&2
    failures=$((failures + 1))
  fi
}

PIN="$(sed -n 's/^GIT_CLIFF_VERSION = "\(.*\)"[[:space:]]*$/\1/p' "$ROOT/mise.toml")"
[[ "$PIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "cannot read an X.Y.Z GIT_CLIFF_VERSION from $ROOT/mise.toml (got '$PIN')" >&2; exit 2; }

# The workflows' checkout: no files, then cone mode on scripts/release, then the commit.
CO="$WORK/release-tools"
git clone -q --no-checkout "file://$ROOT" "$CO" || { echo "cannot clone $ROOT" >&2; exit 2; }
git -C "$CO" sparse-checkout set --cone scripts/release || { echo "cannot set the sparse checkout" >&2; exit 2; }
git -C "$CO" checkout -q "$(git -C "$ROOT" rev-parse HEAD)" || { echo "cannot check out HEAD of $ROOT" >&2; exit 2; }

# Control: the checkout is sparse (a directory outside scripts/release is absent),
# so the next check is about cone mode and not about a full checkout.
[ ! -e "$CO/standards" ] && sparse=ok || sparse=no
check "the checkout is not sparse, so the test would pass without cone mode" "$sparse"

[ -f "$CO/mise.toml" ] && root_file=ok || root_file=no
check "mise.toml is not in the cone checkout of scripts/release" "$root_file"

# The installer, run as the workflows run it, with no argument.
mkdir -p "$WORK/bin" "$WORK/install"
: > "$WORK/curl.log"
cat > "$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in http*) printf '%s\n' "$a" >> "$CURL_LOG" ;; esac; done
exit 22
STUB
chmod +x "$WORK/bin/curl"
out="$(PATH="$WORK/bin:$PATH" CURL_LOG="$WORK/curl.log" GIT_CLIFF_INSTALL_DIR="$WORK/install" \
  bash "$CO/scripts/release/install-git-cliff.sh" 2>&1)"
rc=$?
while IFS= read -r line; do echo "  installer: $line"; done <<< "$out"

[ "$rc" -ne 0 ] && failed=ok || failed=no
check "the installer succeeded against a curl that always fails" "$failed"
grep -qF "/download/v${PIN}/" "$WORK/curl.log" 2>/dev/null && url=ok || url=no
check "the installer did not ask for v${PIN} from the cone checkout (curl saw: $(tr '\n' ' ' < "$WORK/curl.log" 2>/dev/null))" "$url"
[ -z "$(ls -A "$WORK/install")" ] && clean=ok || clean=no
check "the installer left files in the install dir" "$clean"

echo "release-checkout-pin-test: $pass_count passed, $failures failed"
[ "$failures" -eq 0 ]
