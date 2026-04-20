#!/bin/bash
# Shared API call helper for Wharf scripts
# Source this file: source "$SCRIPT_DIR/lib/api.sh"
#
# Provides api_call() with HTTP status checking and clear error messages.
# All functions return the response body on success and exit 1 on failure.

# api_call METHOD URL [CURL_ARGS...]
#
# Makes an HTTP request and checks for 2xx status. Prints response body on
# success. On failure, prints the HTTP status and response body to stderr.
#
# Example:
#   response=$(api_call GET "$GITLAB_API/projects/$id" \
#       --header "PRIVATE-TOKEN: $GITLAB_TOKEN")
api_call() {
    local method="$1"
    local url="$2"
    shift 2

    local tmpfile
    tmpfile=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f '$tmpfile'" RETURN

    local http_code
    http_code=$(curl -s -o "$tmpfile" -w "%{http_code}" \
        --request "$method" \
        "$@" \
        "$url")

    if [[ "$http_code" =~ ^2[0-9]{2}$ ]]; then
        cat "$tmpfile"
        return 0
    else
        echo "ERROR: HTTP $http_code from $method $url" >&2
        if [ -s "$tmpfile" ]; then
            echo "Response: $(head -c 500 "$tmpfile")" >&2
        fi
        return 1
    fi
}

# Convenience wrappers

# api_get URL [CURL_ARGS...]
api_get() {
    api_call GET "$@"
}

# api_post URL [CURL_ARGS...]
api_post() {
    api_call POST "$@"
}

# api_put URL [CURL_ARGS...]
api_put() {
    api_call PUT "$@"
}

# api_delete URL [CURL_ARGS...]
api_delete() {
    api_call DELETE "$@"
}
