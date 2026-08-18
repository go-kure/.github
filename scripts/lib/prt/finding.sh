#!/usr/bin/env bash
# finding.sh — normalize model output, compute fingerprints, assign
# within-run ordinals and collision flags.
#
# fp_base = sha256(netstring(file) + netstring(category))[0:16]. Netstrings
# (length-prefixed, `printf '%d:%s' "${#s}" "$s"`) rather than a delimiter
# join — a plain "file|category" join is ambiguous when either field
# contains the delimiter. `line`, `issue`, `fix`, `severity` are deliberately
# excluded from identity: `line` churns on every push that shifts code above
# a finding, which would mint a fresh thread every push in a `strict: true`,
# rebase-heavy repo.
#
# CATEGORY is a closed enum (mirrors the GitLab design) so the model can't
# rename the same defect across runs by wording it differently. An
# unrecognized value from the model is clamped to "other" rather than
# rejected — the collision/quarantine mechanism below already handles an
# "other" bucket getting crowded; rejecting the finding outright would be a
# worse failure mode than an extra manual-review thread.

set -uo pipefail

PRT_CATEGORIES="nil-deref unchecked-err race sql-injection resource-leak logic-error standards-violation other"

# prt_netstring STR — prints "<len>:<str>" with no trailing newline.
prt_netstring() {
  local s="$1"
  printf '%d:%s' "${#s}" "$s"
}

# prt_fp_base FILE CATEGORY — prints the 16-hex-char base fingerprint.
prt_fp_base() {
  local file="$1" category="$2"
  { prt_netstring "$file"; prt_netstring "$category"; } \
    | sha256sum | cut -c1-16
}

# prt_normalize_category RAW — clamp to the closed enum.
prt_normalize_category() {
  local raw="$1" c
  for c in $PRT_CATEGORIES; do
    if [ "$c" = "$raw" ]; then printf '%s' "$c"; return 0; fi
  done
  printf 'other'
}

# prt_normalize_findings RAW_JSON — validates and filters a model's raw
# findings payload. Prints a normalized JSON array to stdout (each element:
# file, category, line (number|null), severity, issue, fix — all strings
# except line). Prints diagnostics to stderr. Returns 1 (with an empty `[]`
# on stdout) if RAW_JSON's `.findings` is missing/null/not-an-array — the
# caller must treat that as REVIEW_INCOMPLETE, not as "zero findings".
#
# Guards, each independently necessary (an array of scalars passes a bare
# "is array" check; a `.file != ""` check passes a non-string `.file`,
# since an object is never `== ""`):
#   - .findings must be an array
#   - each element must be an object (map(select(type=="object")))
#   - .file must be a non-empty string
#   - a mismatch between raw and filtered counts is reported (caller decides
#     whether to mark REVIEW_INCOMPLETE; dropping a malformed element is not
#     itself fatal, silently losing an unknown number of them is worth a
#     warning either way)
prt_normalize_findings() {
  local raw_json="$1"
  local kind
  kind="$(jq -r 'if (.findings | type) == "array" then "array" else "bad" end' <<< "$raw_json" 2>/dev/null || echo bad)"
  if [ "$kind" != "array" ]; then
    echo "prt_normalize_findings: .findings missing/null/non-array" >&2
    printf '[]'
    return 1
  fi

  local raw_count filtered_count
  raw_count="$(jq '.findings | length' <<< "$raw_json")"

  local objects
  objects="$(jq -c '[.findings[] | select(type=="object")]' <<< "$raw_json")"

  local normalized
  normalized="$(jq -c '
    [ .[]
      | select((.file? | type) == "string" and (.file | length) > 0)
      | select((.category? | type) == "string")
      | select((.severity? | type) == "string")
      | select((.issue? | type) == "string")
      | select((.fix? | type) == "string")
      | {
          file: .file,
          category: .category,
          line: (if (.line? | type) == "number" then .line else null end),
          severity: .severity,
          issue: .issue,
          fix: .fix
        }
    ]' <<< "$objects")"

  filtered_count="$(jq 'length' <<< "$normalized")"
  if [ "$filtered_count" != "$raw_count" ]; then
    echo "prt_normalize_findings: dropped $((raw_count - filtered_count)) of $raw_count malformed finding(s)" >&2
  fi

  # Clamp category to the closed enum (jq can't call the shell function, so
  # this is a second pass over the already-shape-valid array).
  local clamped='[]'
  local i n item category cat
  n="$(jq 'length' <<< "$normalized")"
  for ((i = 0; i < n; i++)); do
    item="$(jq -c ".[$i]" <<< "$normalized")"
    category="$(jq -r '.category' <<< "$item")"
    cat="$(prt_normalize_category "$category")"
    item="$(jq -c --arg cat "$cat" '.category = $cat' <<< "$item")"
    clamped="$(jq -c --argjson item "$item" '. + [$item]' <<< "$clamped")"
  done

  printf '%s' "$clamped"
  return 0
}

# prt_assign_ordinals FINDINGS_JSON — input: normalized findings array
# (prt_normalize_findings output). Output: same elements, each with `fp` (the
# full identity: fp_base, or fp_base-N for the Nth-by-line member of a
# same-file-and-category group) and `collision` (true|false) added.
#
# Multiplicity is the NORMAL case here, not a rare accident — any file with
# two same-category findings collides on fp_base by construction. Ordering
# within a colliding group is by `line` (ties broken by array order), for
# THIS run's assignment only; ordinals are never reassigned across runs by
# re-sorting (that would misattribute a surviving finding onto an unrelated
# pre-existing thread, the exact failure the collision flag exists to
# prevent). Once collision=true, that finding's thread is permanently
# ineligible for automated resolve/reopen — the caller enforces that via
# reconcile.sh row 1, not here.
prt_assign_ordinals() {
  local findings_json="$1"
  local n i item file category fp_base
  n="$(jq 'length' <<< "$findings_json")"

  # Pass 1: compute fp_base per element, stash as a parallel array.
  local with_base='[]'
  for ((i = 0; i < n; i++)); do
    item="$(jq -c ".[$i]" <<< "$findings_json")"
    file="$(jq -r '.file' <<< "$item")"
    category="$(jq -r '.category' <<< "$item")"
    fp_base="$(prt_fp_base "$file" "$category")"
    item="$(jq -c --arg fpb "$fp_base" '. + {fp_base: $fpb}' <<< "$item")"
    with_base="$(jq -c --argjson item "$item" '. + [$item]' <<< "$with_base")"
  done

  # Pass 2: group by fp_base, sort each group by line (nulls last), assign
  # ordinal suffixes and the collision flag. All in jq — pure data shuffling,
  # no further shell/sha256 calls needed.
  jq -c '
    group_by(.fp_base)
    | map(
        (length) as $glen
        | sort_by(if .line == null then 999999999 else .line end)
        | to_entries
        | map(
            .value
            + { collision: ($glen > 1) }
            + { fp: (if .key == 0 then .value.fp_base else (.value.fp_base + "-" + ((.key + 1) | tostring)) end) }
            | del(.fp_base)
          )
      )
    | flatten
  ' <<< "$with_base"
}

# prt_join_assessment FINDINGS_JSON ASSESSMENT_RAW_JSON — joins by `fp`, NOT
# by a shared numeric index (chunking gives each chunk's review call and
# assessment call independent index spaces with no way to map one to the
# other by position). Validates each assessment row: `fp` must match a
# finding in FINDINGS_JSON; `verdict` must be exactly one of VALID,
# PARTIALLY_VALID, FALSE_POSITIVE; `reasoning` must contain a non-whitespace
# character (a bare length check would pass a whitespace-only string).
# Invalid rows are dropped individually (drop-and-continue, never abort the
# whole chunk). A duplicate `fp` across multiple valid rows in one response
# is a contradiction, not evidence for either verdict — every row sharing
# that `fp` is dropped, not arbitrarily one of them kept. A finding with no
# matching (surviving) verdict row keeps `verdict: null` and stays open,
# unreplied — reconcile.sh's VERDICT=NONE path.
prt_join_assessment() {
  local findings_json="$1" assessment_raw="$2"
  local assess_kind
  assess_kind="$(jq -r 'if (.assessments | type) == "array" then "array" else "bad" end' <<< "$assessment_raw" 2>/dev/null || echo bad)"
  if [ "$assess_kind" != "array" ]; then
    echo "prt_join_assessment: .assessments missing/null/non-array; all findings stay unverdicted" >&2
    jq -c '.' <<< "$findings_json"
    return 1
  fi

  local known_fps valid_rows
  known_fps="$(jq -c '[.[].fp]' <<< "$findings_json")"

  # Shape-valid rows only: fp is a known string, verdict is one of the closed
  # three, reasoning is non-blank.
  valid_rows="$(jq -c --argjson known "$known_fps" '
    [ .assessments[]
      | select(type == "object")
      | select((.fp? | type) == "string" and ((.fp) as $f | $known | index($f) != null))
      | select(.verdict == "VALID" or .verdict == "PARTIALLY_VALID" or .verdict == "FALSE_POSITIVE")
      | select((.reasoning? | type) == "string" and (.reasoning | test("[^[:space:]]")))
    ]' <<< "$assessment_raw")"

  # Drop every row sharing an fp that appears more than once among the
  # shape-valid rows — a contradiction within one response is not evidence
  # for either verdict.
  local deduped
  deduped="$(jq -c '
    (group_by(.fp) | map(select(length == 1)) | flatten)
  ' <<< "$valid_rows")"

  jq -c --argjson verdicts "$deduped" '
    . as $findings
    | map(
        . as $f
        | ($verdicts[] | select(.fp == $f.fp)) as $v
        | $f + {verdict: $v.verdict, reasoning: $v.reasoning}
      ) as $matched
    | ($matched | map(.fp)) as $matched_fps
    # IN(), not [x] | inside(y): inside() on strings is substring
    # containment, so a base fp (e.g. "abcd1234") reads as already-matched
    # whenever an unrelated ordinal-suffixed sibling ("abcd1234-2") is in
    # $matched_fps. Wrongly excludes that finding from $unmatched, and since
    # it was never in $matched either (no exact verdict row matched it),
    # this silently dropped the finding from the joined output entirely.
    | ($findings | map(select((.fp | IN($matched_fps[])) | not) + {verdict: null, reasoning: null})) as $unmatched
    | $matched + $unmatched
  ' <<< "$findings_json" 2>/dev/null || jq -c '.' <<< "$findings_json"
}
