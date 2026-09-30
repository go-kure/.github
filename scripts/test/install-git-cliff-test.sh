#!/usr/bin/env bash
# install-git-cliff-test.sh — offline tests for verify_git_cliff_archive and
# main() in scripts/release/install-git-cliff.sh. Throwaway OpenPGP keys are
# generated in a temporary GNUPGHOME and a stub curl serves the release assets,
# so no network and no real key are involved.
#
# Usage: install-git-cliff-test.sh [REPO_ROOT]
# Requires: gpg (gnupg 2.1 or later).

set -uo pipefail  # not -e: report every assertion, not just the first failure

ROOT="${1:-.}"
ROOT="$(cd "$ROOT" && pwd)"

# shellcheck source=/dev/null
source "$ROOT/scripts/release/install-git-cliff.sh"
set +e  # the sourced script turns -e on; this suite reports every failure instead

failures=0
pass_count=0

assert_rc() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $desc — expected rc=$expected, got rc=$actual" >&2
    failures=$((failures + 1))
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $desc — [$needle] not found in [$haystack]" >&2
    failures=$((failures + 1))
  fi
}

WORK="$(mktemp -d)"
KEYHOME="$WORK/gnupg"
mkdir -m 700 "$KEYHOME"
cleanup() {
  gpgconf --homedir "$KEYHOME" --kill all >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

kgpg() {
  gpg --homedir "$KEYHOME" --batch --quiet --pinentry-mode loopback --passphrase '' "$@"
}

primary_fpr() {
  kgpg --with-colons --list-keys "$1" | awk -F: '$1 == "pub" { want = 1; next } want && $1 == "fpr" { print $10; exit }'
}

# Key A is the "pinned" key; it gets a signing subkey too. Key B is a
# stranger whose signatures are cryptographically valid.
kgpg --quick-gen-key 'Pinned Test <pinned@example.invalid>' ed25519 sign never
kgpg --quick-gen-key 'Other Test <other@example.invalid>' ed25519 sign never
FPR_A="$(primary_fpr pinned@example.invalid)"
FPR_B="$(primary_fpr other@example.invalid)"
kgpg --quick-add-key "$FPR_A" ed25519 sign never
SUB_A="$(kgpg --with-colons --list-keys "$FPR_A" | awk -F: '$1 == "sub" { want = 1; next } want && $1 == "fpr" { print $10; exit }')"

if [ -z "$FPR_A" ] || [ -z "$FPR_B" ] || [ -z "$SUB_A" ]; then
  echo "FAIL: could not generate the throwaway keys (FPR_A=$FPR_A FPR_B=$FPR_B SUB_A=$SUB_A)" >&2
  echo "passed: $pass_count, failed: 1"
  exit 1
fi

kgpg --armor --export "$FPR_A" > "$WORK/key-a.asc"
kgpg --armor --export "$FPR_B" > "$WORK/key-b.asc"
kgpg --armor --export "$FPR_A" "$FPR_B" > "$WORK/key-ab.asc"

printf 'pretend git-cliff archive\n' > "$WORK/archive.tar.gz"
kgpg --local-user "${FPR_A}!" --detach-sign --output "$WORK/by-a.sig" "$WORK/archive.tar.gz"
kgpg --local-user "${SUB_A}!" --detach-sign --output "$WORK/by-a-sub.sig" "$WORK/archive.tar.gz"
kgpg --local-user "${FPR_B}!" --detach-sign --output "$WORK/by-b.sig" "$WORK/archive.tar.gz"

verify() {
  OUT="$(verify_git_cliff_archive "$@" 2>&1)"
  RC=$?
}

# 1. Good signature by the pinned primary key.
verify "$WORK/archive.tar.gz" "$WORK/by-a.sig" "$WORK/key-a.asc" "$FPR_A"
assert_rc "good signature by the pinned key passes" 0 "$RC"

# 2. Good signature by the pinned key's signing subkey: VALIDSIG's primary field matches.
verify "$WORK/archive.tar.gz" "$WORK/by-a-sub.sig" "$WORK/key-a.asc" "$FPR_A"
assert_rc "good signature by a subkey of the pinned key passes" 0 "$RC"

# 3. Tampered archive.
cp "$WORK/archive.tar.gz" "$WORK/tampered.tar.gz"
printf 'x' >> "$WORK/tampered.tar.gz"
verify "$WORK/tampered.tar.gz" "$WORK/by-a.sig" "$WORK/key-a.asc" "$FPR_A"
assert_rc "tampered archive fails" 1 "$RC"
assert_contains "tampered archive: reason" "signature verification failed" "$OUT"

# 4. Valid signature by another key, and the key file holds only that key.
verify "$WORK/archive.tar.gz" "$WORK/by-b.sig" "$WORK/key-b.asc" "$FPR_A"
assert_rc "key file without the pinned key fails" 1 "$RC"
assert_contains "key file without the pinned key: reason" "does not contain the pinned primary key" "$OUT"

# 5. Valid signature by another key that the key file also holds: gpg exits 0,
#    so only the VALIDSIG fingerprint check refuses it.
verify "$WORK/archive.tar.gz" "$WORK/by-b.sig" "$WORK/key-ab.asc" "$FPR_A"
assert_rc "valid signature by a non-pinned key in the key file fails" 1 "$RC"
assert_contains "valid signature by a non-pinned key: reason" "not made by the pinned key" "$OUT"

# 6. Missing signature file.
verify "$WORK/archive.tar.gz" "$WORK/absent.sig" "$WORK/key-a.asc" "$FPR_A"
assert_rc "missing .sig fails" 1 "$RC"
assert_contains "missing .sig: reason" "signature not found" "$OUT"

# 7. Malformed pinned fingerprint (lowercase) is refused, not matched loosely.
verify "$WORK/archive.tar.gz" "$WORK/by-a.sig" "$WORK/key-a.asc" "${FPR_A,,}"
assert_rc "lowercase pinned fingerprint is refused" 1 "$RC"

# 8. The fingerprint shipped in the script is well-formed and matches the
#    committed key file's primary key.
shipped="$(gpg --homedir "$KEYHOME" --batch --with-colons --import-options show-only --import "$ROOT/scripts/release/git-cliff-signing-key.asc" 2>/dev/null \
  | awk -F: '$1 == "pub" { want = 1; next } want && $1 == "fpr" { print $10; exit }')"
shipped_ok=1
[ "$shipped" = "$GIT_CLIFF_SIGNING_FPR" ] && shipped_ok=0
assert_rc "committed key file's primary fingerprint equals GIT_CLIFF_SIGNING_FPR" 0 "$shipped_ok"

# 9. main(): verification is enforced on the install path.
#
# The cases above prove verify_git_cliff_archive; these prove main() calls it
# and installs nothing when it refuses. main() takes its key file from the
# directory of the file it was sourced from, and its fingerprint from
# GIT_CLIFF_SIGNING_FPR. So a symlink to the real, unmodified script sits in a
# temporary directory next to key A's key file, and each run sources it in a
# subshell and sets GIT_CLIFF_SIGNING_FPR to key A before calling main. The
# installer carries no test-only override: nothing a caller can set skips the
# verify call. A stub curl, first on PATH only inside that subshell, serves the
# release assets from a per-case fixture directory and fails like curl -f
# (exit 22) for an asset the directory does not hold.
MAINDIR="$WORK/main"
STUBBIN="$WORK/stubbin"
mkdir -p "$MAINDIR" "$STUBBIN"
ln -s "$ROOT/scripts/release/install-git-cliff.sh" "$MAINDIR/install-git-cliff.sh"
cp "$WORK/key-a.asc" "$MAINDIR/git-cliff-signing-key.asc"
cat > "$STUBBIN/curl" <<'STUB'
#!/usr/bin/env bash
out="" url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
src="$CURL_FIXTURES/${url##*/}"
[ -n "$out" ] && [ -f "$src" ] || exit 22
cp "$src" "$out"
STUB
chmod +x "$STUBBIN/curl"

MAIN_VERSION="1.2.3"
MAIN_ASSET="git-cliff-${MAIN_VERSION}-x86_64-unknown-linux-gnu.tar.gz"

# make_release_archive DIR CONTENT — writes DIR/$MAIN_ASSET holding
# git-cliff-$MAIN_VERSION/git-cliff with CONTENT.
make_release_archive() {
  local dir="$1" content="$2" src
  src="$(mktemp -d "$WORK/src.XXXXXX")"
  mkdir -p "$src/git-cliff-${MAIN_VERSION}" "$dir"
  printf '#!/bin/sh\necho %s\n' "$content" > "$src/git-cliff-${MAIN_VERSION}/git-cliff"
  chmod +x "$src/git-cliff-${MAIN_VERSION}/git-cliff"
  tar czf "$dir/$MAIN_ASSET" -C "$src" "git-cliff-${MAIN_VERSION}"
}

# run_main FIXTURES INSTALL_DIR — sets MAIN_OUT (stdout+stderr) and MAIN_RC.
run_main() {
  local fixtures="$1" install_dir="$2"
  mkdir -p "$install_dir"
  MAIN_OUT="$(
    exec 2>&1
    export PATH="$STUBBIN:$PATH" CURL_FIXTURES="$fixtures" GIT_CLIFF_INSTALL_DIR="$install_dir"
    # shellcheck source=/dev/null
    source "$MAINDIR/install-git-cliff.sh"
    # shellcheck disable=SC2034  # read by the sourced main()
    GIT_CLIFF_SIGNING_FPR="$FPR_A"
    main "$MAIN_VERSION"
  )"
  MAIN_RC=$?
}

# Good: an archive signed by the pinned key.
make_release_archive "$WORK/fx-good" "genuine"
kgpg --local-user "${FPR_A}!" --detach-sign --output "$WORK/fx-good/$MAIN_ASSET.sig" "$WORK/fx-good/$MAIN_ASSET"
run_main "$WORK/fx-good" "$WORK/inst-good"
assert_rc "main: archive signed by the pinned key installs" 0 "$MAIN_RC"
installed_ok=1
[ -f "$WORK/inst-good/git-cliff" ] && [ -x "$WORK/inst-good/git-cliff" ] && installed_ok=0
assert_rc "main: installed git-cliff is an executable file" 0 "$installed_ok"
assert_contains "main: installed binary is the signed one" "genuine" "$(cat "$WORK/inst-good/git-cliff" 2>/dev/null)"
assert_contains "main: success line names the verified key" "signature by ${FPR_A} verified" "$MAIN_OUT"

# Tampered: a different, well-formed archive served with the genuine signature
# (a replaced release asset). It would extract and install cleanly if main()
# skipped verification, so only the verify call can stop it.
make_release_archive "$WORK/fx-tampered" "replaced"
cp "$WORK/fx-good/$MAIN_ASSET.sig" "$WORK/fx-tampered/$MAIN_ASSET.sig"
run_main "$WORK/fx-tampered" "$WORK/inst-tampered"
assert_rc "main: tampered archive is refused" 1 "$MAIN_RC"
assert_contains "main: tampered archive: reason" "signature verification failed" "$MAIN_OUT"
assert_contains "main: tampered archive: refusal" "refusing to install git-cliff ${MAIN_VERSION}" "$MAIN_OUT"
assert_contains "main: tampered archive: nothing installed" "[]" "[$(ls -A "$WORK/inst-tampered")]"

# Missing signature asset: the .sig download fails.
make_release_archive "$WORK/fx-nosig" "genuine"
run_main "$WORK/fx-nosig" "$WORK/inst-nosig"
assert_rc "main: missing .sig download is refused" 1 "$MAIN_RC"
assert_contains "main: missing .sig download: reason" "download failed: " "$MAIN_OUT"
assert_contains "main: missing .sig download: names the .sig URL" "$MAIN_ASSET.sig" "$MAIN_OUT"
assert_contains "main: missing .sig download: nothing installed" "[]" "[$(ls -A "$WORK/inst-nosig")]"

echo "passed: $pass_count, failed: $failures"
[ "$failures" -eq 0 ]
