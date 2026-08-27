#!/usr/bin/env bash
# check-label-docs.sh — guard standards/labels.md against drifting from
# standards/labels.json, in both directions.
#
# labels.md is hand-maintained prose; nothing else in this repo checks it
# against the machine-readable source of truth (standards/labels.json). This
# closes that gap the way check-settings-doc.sh closes the equivalent one for
# governance/repository-settings-policy.yaml <-> docs/standards.md.
#
# Scope: any markdown table row under the "## Category Reference" heading,
# up to the next "## " heading or EOF. Parsing is scoped by that one H2, not
# by whatever "### " subheadings sit beneath it (however many, however
# named) — a subheading rename or a collapse from two subsections into one
# flat table needs no edit here. Deprecation ([deprecated] in labels.json /
# **(deprecated)** in labels.md) is checked as a NAMESPACE-level property,
# not per-label: a namespace can be fully deprecated, fully current, or —
# a FAIL either way — partially deprecated, because one labels.md row can't
# represent a mixed namespace.
#
# Two known-weak spots, both fail in the safe direction (they can only
# under-check, never turn a real drift into a false pass elsewhere):
#   - unnamespaced labels (no `::` or `/`) are checked json->doc only: the
#     bare name must appear as a backticked token ANYWHERE in the doc. A
#     token appearing there for an unrelated reason still "passes".
#   - inline color cross-checks skip fenced code blocks entirely: a color
#     inside a fenced example is unchecked, not flagged.
#
# Usage: check-label-docs.sh [REPO_ROOT]

set -euo pipefail
# Sort order affects comm's correctness below; values mix letters, '-', '/'
# and '::', which a UTF-8 locale collates differently than C. Pin it once,
# globally, rather than passing LC_ALL=C to every sort/comm call.
export LC_ALL=C

ROOT="${1:-.}"
ROOT="$(cd "$ROOT" && pwd)"
LABELS_FILE="$ROOT/standards/labels.json"
DOC_FILE="$ROOT/standards/labels.md"

command -v jq &>/dev/null || {
  echo "check-label-docs: jq is required but not installed" >&2
  exit 1
}
[[ -f "$LABELS_FILE" ]] || { echo "check-label-docs: labels file not found: $LABELS_FILE" >&2; exit 1; }
[[ -f "$DOC_FILE" ]] || { echo "check-label-docs: doc file not found: $DOC_FILE" >&2; exit 1; }

# Shape preflight — fatal, not a FAIL: line, because nothing below can trust
# .labels to even be an array once this fails.
jq -e '
  (.labels | type == "array") and (.labels | length > 0) and
  ([.labels[] |
      (.name | type == "string") and (.name | length > 0) and
      (.description | type == "string") and
      (.color | test("^#[0-9A-Fa-f]{6}$"))
   ] | all)
' "$LABELS_FILE" >/dev/null 2>&1 || {
  echo "check-label-docs: standards/labels.json is malformed, empty, or has a label missing name/description or with a malformed color" >&2
  exit 1
}

# Duplicate-name preflight — fatal. A duplicate .name survives the shape
# check above and the later `sort -u` on values silently hides it, so
# github-settings.sh's audit_labels would iterate the same name twice and
# attempt to create it twice on an --apply run.
jq -e '(.labels | map(.name) | unique | length) == (.labels | length)' \
  "$LABELS_FILE" >/dev/null 2>&1 || {
  dupes="$(jq -r '.labels | group_by(.name) | map(select(length > 1) | .[0].name) | join(", ")' "$LABELS_FILE")"
  echo "check-label-docs: standards/labels.json has duplicate label name(s): $dupes" >&2
  exit 1
}

errors=0
fail() { echo "FAIL: $*" >&2; errors=$((errors + 1)); }

# ---------------------------------------------------------------------------
# JSON side: namespace \t bare-value \t deprecated(0|1) \t color(lowercased)
# Classify by '::' before '/' — no label name uses both. An unnamespaced
# label (neither separator) emits namespace="" and bare-value=full name.
# ---------------------------------------------------------------------------
declare -A JSON_VALUES JSON_DEP_COUNT JSON_TOTAL JSON_COLOR
declare -a JSON_UNNAMESPACED

# Field separator is \x1f (ASCII unit separator), not a tab. bash's `read`
# treats tab as "IFS whitespace" regardless of how IFS is set — runs of it
# collapse and leading/trailing occurrences are stripped, silently eating
# the empty $ns field every unnamespaced label produces here (it would land
# in $val instead, shifting every field after it left by one). \x1f is not
# whitespace to `read`, so an empty field between two of it survives intact.
while IFS=$'\x1f' read -r ns val dep color; do
  if [[ -z "$ns" ]]; then
    JSON_UNNAMESPACED+=("$val")
  else
    JSON_VALUES[$ns]="${JSON_VALUES[$ns]:-}$val"$'\n'
    JSON_TOTAL[$ns]=$(( ${JSON_TOTAL[$ns]:-0} + 1 ))
    if [[ "$dep" == "1" ]]; then
      JSON_DEP_COUNT[$ns]=$(( ${JSON_DEP_COUNT[$ns]:-0} + 1 ))
    fi
  fi
  JSON_COLOR["${ns}${val}"]="$color"
done < <(jq -r '
  .labels[]
  | .name as $n
  | (
      if ($n | contains("::")) then (($n | split("::")[0]) + "::")
      elif ($n | contains("/")) then (($n | split("/")[0]) + "/")
      else "" end
    ) as $ns
  | [
      $ns,
      (if $ns == "" then $n else $n[($ns | length):] end),
      (if (.description | startswith("[deprecated]")) then "1" else "0" end),
      (.color | ascii_downcase)
    ]
  | join("")
' "$LABELS_FILE")

# ---------------------------------------------------------------------------
# Doc side: one fence-aware awk pass over every row under "## Category
# Reference", up to the next "## " heading or EOF. Column 3 ("Meaning")
# itself contains backticked label names in its prose (e.g. the status::
# row's own meaning text names `status::blocked`), so a whole-line backtick
# tokenizer would ingest those as values — split on '|' into fields instead.
#
# A row's prefix cell must be exactly one backticked token (optionally
# followed by " **(deprecated)**") to be accepted; anything else under this
# heading that starts with '|' and isn't a header/separator row is emitted
# with backticked=0 so bash below fails it loud rather than skipping it —
# an unbackticked or malformed prefix is a FAIL, never a silent skip.
# ---------------------------------------------------------------------------
declare -A DOC_VALUES DOC_DEP DOC_LINE DOC_SEEN
doc_row_count=0

# \x1f, not tab — see the JSON-side loop above for why: an empty $residue
# field (the common case, a clean row) would otherwise vanish and shift
# $lineno/$rawcell left by one.
while IFS=$'\x1f' read -r pfx backticked dep vals residue lineno rawcell; do
  doc_row_count=$((doc_row_count + 1))
  if [[ "$backticked" != "1" ]]; then
    fail "unparsable table row in the Category Reference table at labels.md line $lineno: $rawcell"
    continue
  fi
  if ! [[ "$pfx" =~ ^[a-z][a-z0-9_-]*(::|/)$ ]]; then
    fail "unparsable table row in the Category Reference table at labels.md line $lineno: prefix '$pfx' is not a valid namespace token"
    continue
  fi
  if [[ -n "${DOC_SEEN[$pfx]:-}" ]]; then
    fail "duplicate labels.md table row for namespace '$pfx' (lines ${DOC_SEEN[$pfx]} and $lineno)"
    continue
  fi
  DOC_SEEN[$pfx]=$lineno
  if [[ -z "$vals" ]]; then
    fail "the labels.md row for '$pfx' (line $lineno) lists no backticked values"
  fi
  if [[ -n "$residue" ]]; then
    fail "the values cell for '$pfx' (labels.md line $lineno) contains text outside backticks: '$residue'"
  fi
  DOC_VALUES[$pfx]="$vals"
  DOC_DEP[$pfx]=$dep
  DOC_LINE[$pfx]=$lineno
done < <(awk '
  BEGIN { FS = "|" }
  /^```/ { fence = !fence; next }
  fence { next }
  /^## / {
    insec = (index($0, "## Category Reference") == 1) ? 1 : 0
    next
  }
  insec == 0 { next }
  $0 !~ /^\|/ { next }
  {
    c1 = $2; c2 = $3
    gsub(/^[ \t]+|[ \t]+$/, "", c1)
    if (c1 ~ /^:?-+:?$/) next
    if (c1 == "Category") next

    dep = (index(c1, "**(deprecated)**") > 0) ? 1 : 0
    tmp = c1
    sub(/[ \t]*\*\*\(deprecated\)\*\*[ \t]*$/, "", tmp)
    gsub(/^[ \t]+|[ \t]+$/, "", tmp)

    if (tmp ~ /^`[^`]+`$/) {
      pfx = substr(tmp, 2, length(tmp) - 2)
      backticked = 1
    } else {
      pfx = tmp
      backticked = 0
    }

    vals = ""; residue = ""
    rest = c2
    while (match(rest, /`[^`]+`/)) {
      residue = residue substr(rest, 1, RSTART - 1)
      v = substr(rest, RSTART + 1, RLENGTH - 2)
      vals = (vals == "" ? v : vals "," v)
      rest = substr(rest, RSTART + RLENGTH)
    }
    residue = residue rest
    gsub(/^[ \t,]+|[ \t,]+$/, "", residue)

    printf "%s\037%d\037%d\037%s\037%s\037%d\037%s\n", pfx, backticked, dep, vals, residue, NR, c1
  }
' "$DOC_FILE")

if [[ "$doc_row_count" -eq 0 ]]; then
  echo "check-label-docs: no table rows found under '## Category Reference' in labels.md — heading renamed or table removed?" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Namespace comparison: union of json/doc namespace keys, so a namespace
# present on only one side is caught before value comparison.
# ---------------------------------------------------------------------------
all_ns="$( { printf '%s\n' "${!JSON_VALUES[@]}"; printf '%s\n' "${!DOC_VALUES[@]}"; } | sort -u)"

while IFS= read -r ns; do
  [[ -z "$ns" ]] && continue
  in_json=0; in_doc=0
  [[ -n "${JSON_VALUES[$ns]+x}" ]] && in_json=1
  [[ -n "${DOC_VALUES[$ns]+x}" ]] && in_doc=1

  if [[ "$in_json" == 1 && "$in_doc" == 0 ]]; then
    fail "namespace '$ns' has ${JSON_TOTAL[$ns]} label(s) in labels.json but no row in the labels.md Category Reference table"
    continue
  fi
  if [[ "$in_doc" == 1 && "$in_json" == 0 ]]; then
    fail "labels.md has a table row for namespace '$ns' (line ${DOC_LINE[$ns]}) but labels.json has no label in that namespace"
    continue
  fi

  json_vals_sorted="$(printf '%s' "${JSON_VALUES[$ns]}" | sort -u)"
  doc_vals_sorted="$(printf '%s' "${DOC_VALUES[$ns]}" | tr ',' '\n' | sort -u)"
  only_json="$(comm -23 <(echo "$json_vals_sorted") <(echo "$doc_vals_sorted") | sed '/^$/d')"
  only_doc="$(comm -13 <(echo "$json_vals_sorted") <(echo "$doc_vals_sorted") | sed '/^$/d')"

  if [[ -n "$only_json" ]]; then
    while IFS= read -r v; do
      fail "'$v' is in labels.json ('${ns}${v}') but not listed in the labels.md '$ns' row"
    done <<<"$only_json"
  fi
  if [[ -n "$only_doc" ]]; then
    while IFS= read -r v; do
      fail "'$v' is enumerated in labels.md but there is no '${ns}${v}' in labels.json"
    done <<<"$only_doc"
  fi

  total=${JSON_TOTAL[$ns]}
  depc=${JSON_DEP_COUNT[$ns]:-0}
  docdep=${DOC_DEP[$ns]}
  if [[ "$depc" -eq "$total" && "$docdep" != "1" ]]; then
    fail "all $total label(s) in '$ns' are '[deprecated]' in labels.json but the labels.md row (line ${DOC_LINE[$ns]}) is not marked '**(deprecated)**'"
  elif [[ "$depc" -eq 0 && "$docdep" == "1" ]]; then
    fail "the labels.md row for '$ns' (line ${DOC_LINE[$ns]}) is marked '**(deprecated)**' but no label in that namespace has a '[deprecated]' description in labels.json"
  elif [[ "$depc" -gt 0 && "$depc" -lt "$total" ]]; then
    fail "namespace '$ns' is partially deprecated in labels.json ($depc of $total) — a single labels.md row cannot represent a mixed namespace; deprecate all of them or split the row"
  fi
done <<<"$all_ns"

# ---------------------------------------------------------------------------
# Unnamespaced labels: json->doc only. Presence-only, whole-token match
# against every backticked token anywhere in labels.md (not scoped to the
# Category Reference table — these labels are documented in prose).
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016 # single-quoted on purpose: a literal regex
# matching markdown backticks, not a string meant to expand.
doc_tokens="$(grep -oE '`[^`]+`' "$DOC_FILE" | tr -d '`' | sort -u || true)"
for lbl in "${JSON_UNNAMESPACED[@]:-}"; do
  [[ -z "$lbl" ]] && continue
  if ! grep -qxF "$lbl" <<<"$doc_tokens"; then
    fail "'$lbl' is in labels.json but never appears as a backticked token in labels.md"
  fi
done

# ---------------------------------------------------------------------------
# Inline colors: a second fence-aware awk pass collecting, per line, every
# color-looking hex code (preceding char non-alphanumeric, following char
# not a hex digit — rejects both '.github#123456' and '#0052CCA') and every
# backticked token on that same line. Bash then requires exactly one of that
# line's tokens to be a known label name: 0 is a color with no owner, >=1
# ambiguous choices is "put one label per line".
# ---------------------------------------------------------------------------
color_count=0
# \x1f, not tab — $toks is legitimately empty on a line with a color but no
# backticked token, which tab-as-IFS-whitespace would collapse away.
while IFS=$'\x1f' read -r color toks lineno; do
  declare -A seen_tok=()
  matches=()
  IFS=',' read -ra tok_arr <<<"$toks"
  for t in "${tok_arr[@]}"; do
    if [[ -n "${JSON_COLOR[$t]+x}" && -z "${seen_tok[$t]+x}" ]]; then
      matches+=("$t")
      seen_tok[$t]=1
    fi
  done
  case "${#matches[@]}" in
    0)
      fail "color '$color' at labels.md line $lineno names no labels.json label on the same line — put a color on the same line as its backticked label name"
      ;;
    1)
      jc="${JSON_COLOR[${matches[0]}]}"
      if [[ "$color" != "$jc" ]]; then
        fail "color '$color' at labels.md line $lineno does not match labels.json color '$jc' for '${matches[0]}'"
      fi
      color_count=$((color_count + 1))
      ;;
    *)
      joined="$(IFS=,; echo "${matches[*]}")"
      fail "color '$color' at labels.md line $lineno is ambiguous: ${#matches[@]} label name(s) on that line ($joined) — one label per line"
      ;;
  esac
done < <(awk '
  /^```/ { fence = !fence; next }
  fence { next }
  {
    line = $0
    toks = ""
    t = line
    while (match(t, /`[^`]+`/)) {
      toks = (toks == "" ? substr(t, RSTART + 1, RLENGTH - 2) : toks "," substr(t, RSTART + 1, RLENGTH - 2))
      t = substr(t, RSTART + RLENGTH)
    }
    consumed = 0
    c = line
    while (match(c, /#[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]/)) {
      startpos = consumed + RSTART
      prevc = (startpos > 1) ? substr(line, startpos - 1, 1) : ""
      nextidx = startpos + RLENGTH
      nextc = (nextidx <= length(line)) ? substr(line, nextidx, 1) : ""
      if (prevc !~ /[A-Za-z0-9]/ && nextc !~ /[0-9A-Fa-f]/) {
        printf "%s\037%s\037%d\n", tolower(substr(c, RSTART, RLENGTH)), toks, NR
      }
      consumed += RSTART + RLENGTH - 1
      c = substr(line, consumed + 1)
    }
  }
' "$DOC_FILE")

if [[ "$errors" -gt 0 ]]; then
  echo "check-label-docs: $errors violation(s)." >&2
  exit 1
fi

total_labels=$(jq '.labels | length' "$LABELS_FILE")
ns_count=${#JSON_VALUES[@]}
echo "check-label-docs: OK ($total_labels label(s), $ns_count namespace(s), $color_count inline color(s) verified)."
