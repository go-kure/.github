#!/usr/bin/env bash
# install-git-cliff.sh — download a git-cliff release binary, verify its
# upstream OpenPGP signature against a pinned key, and install it.
#
#   install-git-cliff.sh <version>
#       <version> is X.Y.Z, without the leading v (the value of the callers'
#       Renovate-managed CLIFF_VERSION line). Downloads the
#       x86_64-unknown-linux-gnu .tar.gz and its .tar.gz.sig from the orhun/git-cliff
#       release, verifies the signature, then installs the binary into
#       GIT_CLIFF_INSTALL_DIR (default /usr/local/bin; sudo is used only when that
#       directory is not writable).
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

ensure_gpg() {
    command -v gpg >/dev/null 2>&1 && return 0
    echo "install-git-cliff: gpg not found, installing gnupg" >&2
    sudo apt-get update -qq
    sudo apt-get install -y -qq --no-install-recommends gnupg
    command -v gpg >/dev/null 2>&1 || die "gpg still not available after installing gnupg"
}

main() {
    [ $# -eq 1 ] || { echo "Usage: $0 <version>" >&2; exit 2; }
    local version="$1"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "install-git-cliff: version must be X.Y.Z (no leading v), got: $version" >&2; exit 2; }

    local keyfile install_dir work name url
    keyfile="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/git-cliff-signing-key.asc"
    install_dir="${GIT_CLIFF_INSTALL_DIR:-/usr/local/bin}"

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
        sudo install -m755 "$work/git-cliff-${version}/git-cliff" "$install_dir/git-cliff"
    fi
    echo "install-git-cliff: installed git-cliff ${version} (signature by ${GIT_CLIFF_SIGNING_FPR} verified) into ${install_dir}"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
