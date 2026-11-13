#!/usr/bin/env bash
# install-git-cliff.sh — download a git-cliff release binary, verify its
# upstream OpenPGP signature against a pinned key, and install it.
#
#   install-git-cliff.sh [<version>]
#       <version> is X.Y.Z, without the leading v. Left out, it is the
#       GIT_CLIFF_VERSION under [env] in the mise.toml two directories above this
#       script: the one place the version is written, which Renovate bumps and
#       which release.yml, release-publish.yml, ci.yml and `mise run verify` all
#       read through this script. Downloads the
#       x86_64-unknown-linux-gnu .tar.gz and its .tar.gz.sig from the orhun/git-cliff
#       release, verifies the signature, then installs the binary into
#       GIT_CLIFF_INSTALL_DIR (default /usr/local/bin; `sudo -n` is used only when
#       that directory is not writable, and the script exits at once, before any
#       download, when sudo would ask for a password). A missing install dir is
#       created first, without sudo, when its parent allows. When the git-cliff in
#       GIT_CLIFF_INSTALL_DIR already prints exactly "git-cliff <version>" for
#       --version, nothing is downloaded or installed; a binary elsewhere on PATH
#       never counts, because its provenance is unknown.
#
# The signature must verify, and its VALIDSIG status line must name
# GIT_CLIFF_SIGNING_FPR below as the signing key's primary key. The key itself
# comes from git-cliff-signing-key.asc next to this script, imported into a
# throwaway GNUPGHOME, so nothing on the runner's own keyring is trusted or
# changed. Any failure — download, missing key, bad or foreign signature —
# exits non-zero before anything is installed.
#
# A signing-key rotation upstream is a deliberate change here: replace
# git-cliff-signing-key.asc and GIT_CLIFF_SIGNING_FPR in the same PR, after
# checking the new fingerprint against git-cliff's own installation docs. The
# fingerprint lives only in this file, never on a line Renovate rewrites.
#
# gnupg is installed with apt-get when gpg is missing.
#
# Tests: scripts/test/install-git-cliff-test.sh (sources this file and calls
# verify_git_cliff_archive and main with a throwaway key and a stub curl).

set -euo pipefail

# git-cliff's release signing key, as published in its installation docs
# (website/docs/installation/binary-releases.md in the git-cliff repository).
GIT_CLIFF_SIGNING_FPR="1D2D410A741137EBC544826F4A92FA17B6619297"
GIT_CLIFF_TARGET="x86_64-unknown-linux-gnu"

die() {
    echo "install-git-cliff: $*" >&2
    exit 1
}

# verify_git_cliff_archive TARBALL SIG KEYFILE FPR
# Return 0 only when SIG is a good signature over TARBALL made by the key whose
# primary fingerprint is FPR, with that key taken from KEYFILE. Prints the
# reason on stderr and returns 1 otherwise.
verify_git_cliff_archive() {
    local tarball="$1" sig="$2" keyfile="$3" fpr="$4"
    local gnupghome status rc=0

    [ -f "$tarball" ] || { echo "install-git-cliff: archive not found: $tarball" >&2; return 1; }
    [ -f "$sig" ] || { echo "install-git-cliff: signature not found: $sig" >&2; return 1; }
    [ -f "$keyfile" ] || { echo "install-git-cliff: key file not found: $keyfile" >&2; return 1; }
    [[ "$fpr" =~ ^[0-9A-F]{40}$ ]] || { echo "install-git-cliff: pinned fingerprint is not 40 uppercase hex digits: $fpr" >&2; return 1; }

    gnupghome="$(mktemp -d)"
    chmod 700 "$gnupghome"

    if ! gpg --homedir "$gnupghome" --batch --quiet --import "$keyfile" 2>/dev/null; then
        echo "install-git-cliff: could not import $keyfile" >&2
        rc=1
    elif ! gpg --homedir "$gnupghome" --batch --with-colons --list-keys 2>/dev/null \
            | awk -F: -v fpr="$fpr" '$1 == "pub" { want = 1; next } want && $1 == "fpr" { if ($10 == fpr) found = 1; want = 0 } END { exit found ? 0 : 1 }'; then
        echo "install-git-cliff: $keyfile does not contain the pinned primary key $fpr" >&2
        rc=1
    else
        # gpg's exit status alone accepts a good signature by ANY key in the
        # imported file; the VALIDSIG line's last field is the signing key's
        # primary fingerprint, so a subkey signature of the pinned key passes
        # and a signature by any other key does not. A line without that field
        # (12 whitespace-separated fields in all) is rejected, not guessed at.
        if status="$(gpg --homedir "$gnupghome" --batch --status-fd 1 --verify "$sig" "$tarball" 2>/dev/null)"; then
            if ! awk -v fpr="$fpr" '$1 == "[GNUPG:]" && $2 == "VALIDSIG" && NF == 12 && $12 == fpr { found = 1 } END { exit found ? 0 : 1 }' <<< "$status"; then
                echo "install-git-cliff: signature on $tarball is valid but was not made by the pinned key $fpr" >&2
                rc=1
            fi
        else
            echo "install-git-cliff: signature verification failed for $tarball" >&2
            rc=1
        fi
    fi

    gpgconf --homedir "$gnupghome" --kill all >/dev/null 2>&1 || true
    rm -rf "$gnupghome"
    return "$rc"
}

# need_sudo WHAT
# Succeed only when sudo can run without a password. An unattended run has no
# way to answer a password prompt, so a bare sudo would wait for ever with no
# output and no exit code; fail at once and say what to do instead.
need_sudo() {
    sudo -n true 2>/dev/null || die "$1 needs root and sudo asks for a password: set GIT_CLIFF_INSTALL_DIR to a writable directory (and install gnupg yourself if gpg is missing)"
}

ensure_gpg() {
    command -v gpg >/dev/null 2>&1 && return 0
    echo "install-git-cliff: gpg not found, installing gnupg" >&2
    need_sudo "installing gnupg"
    sudo -n apt-get update -qq
    sudo -n apt-get install -y -qq --no-install-recommends gnupg
    command -v gpg >/dev/null 2>&1 || die "gpg still not available after installing gnupg"
}

# already_installed VERSION INSTALL_DIR
# Succeed when the git-cliff in INSTALL_DIR answers --version with exactly
# "git-cliff VERSION". Any other answer (a different or longer version, an
# unparsable line, no binary) fails, so the install goes ahead and its
# signature check runs. Only INSTALL_DIR counts: that is where this script puts
# a verified binary, whereas a binary elsewhere on PATH reports a version with
# no known provenance and must never stand in for the signature check.
already_installed() {
    local version="$1" bin="$2/git-cliff"
    [ -x "$bin" ] || return 1
    [ "$("$bin" --version 2>/dev/null || true)" = "git-cliff ${version}" ]
}

# pinned_version MISE_TOML
# Print the X.Y.Z that GIT_CLIFF_VERSION is set to under [env] in MISE_TOML, the
# one place the version is written. Dies, naming the file, when the file is
# missing or holds no such line, more than one, or a value that is not X.Y.Z.
pinned_version() {
    local mise="$1" lines version
    [ -f "$mise" ] || die "no $mise: the version is read from GIT_CLIFF_VERSION in the mise.toml two directories above this script (or pass <version>)"
    # The range runs from the [env] header to the next table header (TOML allows
    # whitespace before one), so the same key in another table, or above every
    # table, is not read.
    lines="$(sed -n '/^\[env\][[:space:]]*$/,/^[[:space:]]*\[/ s/^GIT_CLIFF_VERSION = "\(.*\)"[[:space:]]*$/\1/p' "$mise")"
    [ -n "$lines" ] || die "no GIT_CLIFF_VERSION = \"X.Y.Z\" line under [env] in $mise"
    [ "$(printf '%s\n' "$lines" | wc -l)" -eq 1 ] || die "more than one GIT_CLIFF_VERSION line under [env] in $mise"
    version="$lines"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "GIT_CLIFF_VERSION in $mise must be X.Y.Z (no leading v), got: $version"
    printf '%s\n' "$version"
}

main() {
    local version
    case $# in
        0) version="$(pinned_version "$(dirname "${BASH_SOURCE[0]}")/../../mise.toml")" || exit 1 ;;
        1) version="$1" ;;
        *) echo "Usage: $0 [<version>]" >&2; exit 2 ;;
    esac
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "install-git-cliff: version must be X.Y.Z (no leading v), got: $version" >&2; exit 2; }

    local keyfile install_dir work name url
    keyfile="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/git-cliff-signing-key.asc"
    install_dir="${GIT_CLIFF_INSTALL_DIR:-/usr/local/bin}"

    if already_installed "$version" "$install_dir"; then
        echo "install-git-cliff: git-cliff ${version} already installed, nothing to do"
        return 0
    fi

    # A fresh checkout has no .tools/bin, and a missing directory is not
    # writable: create it first, as this user, when its parent allows. Then
    # decide before downloading anything: an install dir this user cannot write
    # needs passwordless sudo.
    [ -d "$install_dir" ] || mkdir -p "$install_dir" 2>/dev/null || true
    [ -w "$install_dir" ] || need_sudo "installing into ${install_dir}"

    ensure_gpg

    work="$(mktemp -d)"
    # shellcheck disable=SC2064  # expand now: $work is local to main
    trap "rm -rf '$work'" EXIT

    name="git-cliff-${version}-${GIT_CLIFF_TARGET}.tar.gz"
    url="https://github.com/orhun/git-cliff/releases/download/v${version}/${name}"
    curl -fsSL -o "$work/$name" "$url" || die "download failed: $url"
    curl -fsSL -o "$work/$name.sig" "$url.sig" || die "download failed: $url.sig"

    verify_git_cliff_archive "$work/$name" "$work/$name.sig" "$keyfile" "$GIT_CLIFF_SIGNING_FPR" \
        || die "refusing to install git-cliff ${version}"

    tar xzf "$work/$name" -C "$work"
    [ -f "$work/git-cliff-${version}/git-cliff" ] || die "archive has no git-cliff-${version}/git-cliff"

    if [ -w "$install_dir" ]; then
        install -m755 "$work/git-cliff-${version}/git-cliff" "$install_dir/git-cliff"
    else
        sudo -n install -D -m755 "$work/git-cliff-${version}/git-cliff" "$install_dir/git-cliff"
    fi
    echo "install-git-cliff: installed git-cliff ${version} (signature by ${GIT_CLIFF_SIGNING_FPR} verified) into ${install_dir}"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
