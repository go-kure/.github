#!/usr/bin/env bash
# json.sh — stdin-only transforms for JSON collections that may exceed
# Linux's per-argument execve limit. Callers keep the old accumulator unless
# the helper returns success.

set -uo pipefail

# prt_json_extract_inventory_page KIND PAYLOAD -> compact validated page
# KIND is review_threads (the top-level connection) or comments (a follow-up
# comment connection). PAYLOAD is untrusted GraphQL .data JSON and reaches jq
# only through stdin. Returns nonzero with no output on any schema mismatch.
prt_json_extract_inventory_page() {
  local kind="$1" payload="$2"
  case "$kind" in review_threads|comments) : ;; *) return 1 ;; esac

  printf '%s\n' "$payload" |
    jq -ce --arg kind "$kind" '
      def valid_page_info:
        type == "object"
        and (.hasNextPage | type) == "boolean"
        and ((.hasNextPage == false)
             or ((.endCursor | type) == "string" and (.endCursor | length) > 0));
      def valid_comment:
        type == "object"
        and (.id | type) == "string" and (.id | length) > 0
        and (.databaseId | type) == "number"
        and (.body | type) == "string"
        and ((.author == null)
             or ((.author | type) == "object" and (.author.login | type) == "string"));
      def valid_comments:
        type == "object"
        and (.nodes | type) == "array"
        and (.pageInfo | valid_page_info)
        and all(.nodes[]; valid_comment);
      def valid_thread:
        type == "object"
        and (.id | type) == "string" and (.id | length) > 0
        and (.isResolved | type) == "boolean"
        and (.isOutdated | type) == "boolean"
        and ((.resolvedBy == null)
             or ((.resolvedBy | type) == "object" and (.resolvedBy.login | type) == "string"))
        and (.viewerCanResolve | type) == "boolean"
        and (.viewerCanUnresolve | type) == "boolean"
        and (.comments | valid_comments);
      def valid_threads:
        type == "object"
        and (.nodes | type) == "array"
        and (.pageInfo | valid_page_info)
        and all(.nodes[]; valid_thread);

      if $kind == "review_threads" then
        .repository.pullRequest.reviewThreads | select(valid_threads)
      else
        .node.comments | select(valid_comments)
      end
    ' 2>/dev/null
}

# prt_json_concat_arrays LEFT RIGHT -> compact concatenated array
# Both values travel from the Bash builtin printf to jq over stdin, never as
# --argjson values on jq's argv. Returns nonzero with no output unless both
# inputs are valid JSON arrays.
prt_json_concat_arrays() {
  local left="$1" right="$2"
  printf '%s\n%s\n' "$left" "$right" |
    jq -ces '
      if length == 2 and all(.[]; type == "array") then
        .[0] + .[1]
      else
        error("expected exactly two JSON arrays")
      end
    ' 2>/dev/null
}

# prt_json_append_thread_comments THREADS INDEX EXTRA_COMMENTS
# Appends EXTRA_COMMENTS to THREADS[INDEX].comments.nodes. Both unbounded
# arrays use stdin; INDEX remains a bounded scalar argv value. Returns nonzero
# with no output on malformed input or an invalid target path/index.
prt_json_append_thread_comments() {
  local threads="$1" index="$2" extra="$3"
  printf '%s\n%s\n' "$threads" "$extra" |
    jq -ces --argjson i "$index" '
      if length != 2 or any(.[]; type != "array") then
        error("expected exactly two JSON arrays")
      elif ($i | type) != "number" or ($i | floor) != $i or $i < 0 or $i >= (.[0] | length) then
        error("invalid thread index")
      elif (.[0][$i] | type) != "object" or (.[0][$i].comments | type) != "object"
           or (.[0][$i].comments.nodes | type) != "array" then
        error("invalid thread comment path")
      else
        .[0] as $threads
        | .[1] as $extra
        | $threads
        | .[$i].comments.nodes += $extra
      end
    ' 2>/dev/null
}
