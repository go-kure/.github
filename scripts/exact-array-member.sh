#!/usr/bin/env bash
# Sourceable exact array-membership helper.
#
# Usage:
#   if exact_array_member "$needle" "${values[@]}"; then
#     ...
#   fi
#
# A shell loop avoids the producer SIGPIPE that can make
# `printf ... | grep -q` fail under `set -o pipefail`.

exact_array_member() {
  local needle="$1"
  shift

  local value
  for value in "$@"; do
    if [[ "$value" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}
