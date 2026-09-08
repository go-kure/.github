#!/usr/bin/env bash
# parse-reviews.sh -- turn a corpus of review ledgers into one CSV of adjudicated findings.
#
# The corpus is finding -> outcome -> reason, with the reason written by whoever adjudicated
# it. It has been parsed by hand at least three times to produce rates quoted in prose, and
# no script that does it existed, which makes every one of those numbers unreproducible. This
# is that script. It is the secondary half of the measurement work: the gold-set harness
# measures a reviewer, this measures the adjudication.
#
# Two record kinds, both emitted into one CSV:
#
#   ledger        a row of a plan-loop findings ledger:
#                 | ID | source | class | rule | found at | status | (delta) |
#                 `status` is taken as the first word of the status cell, `reason` as the
#                 rest. Older ledgers have no trailing delta column; both widths parse.
#   verification  a limb of a `## VERIFICATION` block in a review file, of the shape
#                 `  confirmed — <text>`, attributed to the finding id most recently named.
#                 These blocks are prose, so this half is a HEURISTIC: it will miss a limb
#                 written in another shape. Treat its counts as a floor, never as a total.
#
# The corpus is large (hundreds of directories, and a sibling transcript tree that has hung
# this host once). Nothing here recurses: `find` builds a bounded, dated file list and each
# file is processed individually.
#
# exit status
#   0  rows written      1  no rows found      2  usage or environment error

set -uo pipefail

readonly PROG=${0##*/}

die() {
    printf '%s: %s\n' "$PROG" "$*" >&2
    exit 2
}

log() { printf '%s: %s\n' "$PROG" "$*" >&2; }

usage() {
    cat <<'EOF'
usage: parse-reviews.sh --out <file.csv> [--reviews-dir <dir>] [--since <date>]

  --out           CSV destination (required)
  --reviews-dir   corpus root (default: $HOME/.claude/reviews)
  --since         only read files modified since this date (default: 2 years ago)
  --summary       also print the rates the corpus supports, to stderr

CSV columns: source_file,kind,finding,class,rule,status,reason

exit status
  0  rows written      1  no rows found      2  usage error
EOF
}

out_file=
reviews_dir="${HOME}/.claude/reviews"
since='2 years ago'
want_summary=false

while [ $# -gt 0 ]; do
    case "$1" in
        --out) out_file=${2-}; shift 2 || die "--out needs a value" ;;
        --reviews-dir) reviews_dir=${2-}; shift 2 || die "--reviews-dir needs a value" ;;
        --since) since=${2-}; shift 2 || die "--since needs a value" ;;
        --summary) want_summary=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ -n "$out_file" ] || die "--out is required"
[ -d "$reviews_dir" ] || die "no such directory: $reviews_dir"

since_stamp=$(date -d "$since" '+%Y-%m-%d' 2>/dev/null) || die "unparseable --since: $since"

# ---------------------------------------------------------------------------
# the two parsers
# ---------------------------------------------------------------------------

# Shared CSV emitter, RFC 4180: a field is quoted and its own quotes doubled. Ledger reasons
# routinely contain commas, backticks and quoted paths, so an unquoted join would corrupt the
# file in exactly the rows worth reading.
read -r -d '' CSV_LIB <<'AWK' || true
function csv(s) {
    gsub(/\r/, "", s)
    gsub(/"/, "\"\"", s)
    return "\"" s "\""
}
function trim(s) {
    sub(/^[ \t]+/, "", s)
    sub(/[ \t]+$/, "", s)
    # Undo the escaped-pipe protection applied per record (see LEDGER_AWK's BEGIN). Harmless
    # for the other programs sharing this prelude: they never introduce the sentinel, and
    # \001 is not a character a Markdown ledger can otherwise contain.
    gsub(/\001/, "|", s)
    return s
}
AWK

read -r -d '' LEDGER_AWK <<'AWK' || true
# HEADER-DRIVEN, not position-driven. Measured over the corpus on 2026-09-07, the ledger
# header has at least 20 spellings: the column count runs 3 to 7, the case alternates
# (`| ID | Source |` vs `| ID | source |`), and the OID column is variously "Hash found at",
# "Plan hash found at", "OID found at", "Found-at OID" or absent. A parser keyed on one
# spelling and fixed field numbers read 715 rows where the corpus holds several thousand, and
# mislabelled the class column of every table whose width it guessed wrong -- a wrong number
# that looks exactly like a right one.
BEGIN { FS = "|"; in_table = 0 }

# An escaped pipe is cell CONTENT, not a delimiter -- and a ledger's `issue` or `rule` cell
# routinely holds one, since `\|` is how Markdown carries a pipe inside a table. FS splits on
# it anyway, so a single `\|` anywhere left of the status column shifts every header-derived
# index by one and the row silently reports the wrong class, rule or status. Header-driven
# indexing does not save us here: the header row rarely contains an escape, so the columns are
# mapped correctly and only the data rows slide. Protect the escapes before the split, and
# restore them in trim() as each cell is read. Assigning to $0 is what forces the re-split.
{
    _line = $0
    if (gsub(/\\\|/, "\001", _line)) $0 = _line
}

function header_row(  i, name, found_id, found_status) {
    delete col
    found_id = 0; found_status = 0
    for (i = 2; i <= NF; i++) {
        name = tolower(trim($i))
        gsub(/\*/, "", name)
        if (name == "id") { col["id"] = i; found_id = 1 }
        else if (name == "source" || name == "source label" || name == "lens") col["source"] = i
        else if (name == "class") col["class"] = i
        else if (name == "rule") col["rule"] = i
        else if (name == "status") { col["status"] = i; found_status = 1 }
    }
    return (found_id && found_status)
}

/^\|/ && !in_table {
    if (header_row()) { in_table = 1; next }
}

# The separator row under the header. Anything that is not a table row ends the table.
/^\|[ \t]*:?-+/ { next }
!/^\|/ { in_table = 0; next }

in_table {
    id = trim($col["id"])
    if (id == "" || tolower(id) == "id") next

    cls = ("class" in col) ? trim($col["class"]) : ""
    rule = ("rule" in col) ? trim($col["rule"]) : ""
    status_cell = trim($col["status"])

    # The status cell is "<keyword> — <reason>"; older rows are the bare keyword. Split on
    # the em dash, not on whitespace: a reason's own first word is not a status.
    status = status_cell
    reason = ""
    if (status_cell ~ /—/) {
        # Split with regex, never with index()+substr() arithmetic. The `substr(cell, idx + 3)`
        # that stood here offset a CHARACTER index by the em dash's BYTE length: gawk in a
        # UTF-8 locale makes index() and substr() character-based, so it skipped the dash plus
        # two further characters and silently truncated the first characters of every reason.
        # It was correct only under a byte-oriented awk such as mawk -- a defect whose presence
        # depends on the interpreter rather than the data. This is the form VERIFY_AWK uses.
        status = status_cell
        sub(/—.*$/, "", status)
        status = trim(status)
        reason = status_cell
        sub(/^[^—]*—[ \t]*/, "", reason)
        reason = trim(reason)
    }
    # Strip emphasis and any parenthetical: "**rejected** (wrong premise)" is `rejected`.
    gsub(/\*/, "", status)
    sub(/[ (].*$/, "", status)

    print csv(FILE) "," csv("ledger") "," csv(id) "," csv(cls) "," csv(rule) "," \
        csv(tolower(status)) "," csv(reason)
}
AWK

read -r -d '' VERIFY_AWK <<'AWK' || true
# The dominant shape, measured over the 192 corpus files carrying the heading, is one line:
#
#   F1 confirmed  — <reason, continuing on indented lines>
#   (a) CONFIRMED as a checked negative, ...
#   - **Checked-negative — <subject>:** <reason>
#     refuted   — <reason>
#
# so the verdict is USUALLY NOT at line start. Keying on a line-leading verdict token found
# 11 limbs in the whole corpus while 192 files carried the heading -- a checker that ran and
# reported almost nothing, which reads identically to a corpus that holds almost nothing.
#
# Known limit, stated rather than hidden: only the FIRST line of a limb is captured, so a
# reason continuing onto indented lines is truncated. Every verdict is still counted; the
# reason column is a summary, not a transcript.
BEGIN { in_block = 0; finding = "" }

/^#+[ \t]*VERIFICATION/ { in_block = 1; next }
# Any other heading of the same or a shallower level closes the block.
/^#+[ \t]/ { in_block = 0; next }

in_block {
    line = $0
    # The finding id: "F1 ...", "C14 ...", "(a) ..." or a bolded bullet subject.
    if (match(line, /^[A-Z]+[0-9]+/)) {
        finding = substr(line, RSTART, RLENGTH)
    } else if (match(line, /^\([a-z0-9]+\)/)) {
        finding = substr(line, RSTART + 1, RLENGTH - 2)
    }

    # The verdict may sit anywhere before the em dash or colon that opens the reason. Bound
    # the search to the head of the line so a reason merely CONTAINING the word "confirmed"
    # does not mint a limb.
    head = substr(line, 1, 60)
    verdict = ""
    if (match(tolower(head), /checked-negative/)) verdict = "checked-negative"
    else if (match(tolower(head), /unreproducible/)) verdict = "unreproducible"
    else if (match(tolower(head), /refuted/)) verdict = "refuted"
    else if (match(tolower(head), /confirmed/)) verdict = "confirmed"
    if (verdict == "") next

    reason = line
    if (index(reason, "—") > 0) {
        sub(/^[^—]*—[ \t]*/, "", reason)
    } else {
        sub(/^[^:]*:[ \t]*/, "", reason)
    }
    gsub(/\*/, "", reason)

    print csv(FILE) "," csv("verification") "," csv(finding) "," csv("") "," csv("") "," \
        csv(verdict) "," csv(trim(reason))
}
AWK

# ---------------------------------------------------------------------------
# walk the bounded file list
# ---------------------------------------------------------------------------

tmp=$(mktemp "${TMPDIR:-/tmp}/parse-reviews.XXXXXX") || die "mktemp failed"
trap 'rm -f "$tmp"' EXIT

printf 'source_file,kind,finding,class,rule,status,reason\n' >"$tmp"

n_ledgers=0
while IFS= read -r -d '' f; do
    awk -v FILE="$f" "$CSV_LIB$LEDGER_AWK" "$f" >>"$tmp" || log "awk failed on $f"
    n_ledgers=$((n_ledgers + 1))
done < <(find "$reviews_dir" -mindepth 2 -maxdepth 2 -type f -name 'ledger.md' \
    -newermt "$since_stamp" -print0)

n_reviews=0
while IFS= read -r -d '' f; do
    awk -v FILE="$f" "$CSV_LIB$VERIFY_AWK" "$f" >>"$tmp" || log "awk failed on $f"
    n_reviews=$((n_reviews + 1))
done < <(find "$reviews_dir" -maxdepth 1 -type f -name '*.md' -newermt "$since_stamp" -print0)

rows=$(($(wc -l <"$tmp") - 1))
log "read $n_ledgers ledgers and $n_reviews review files since $since_stamp; $rows rows"

if [ "$rows" -le 0 ]; then
    log "no rows parsed"
    exit 1
fi

cat "$tmp" >"$out_file" || die "cannot write $out_file"
log "wrote $out_file"

# ---------------------------------------------------------------------------
# the rates the corpus actually supports
# ---------------------------------------------------------------------------

if [ "$want_summary" = true ]; then
    awk -F',' '
        # The class cell is free text, not an enum: the corpus holds 60+ spellings, most of
        # them one of four words plus a parenthetical ("blocking (A2 witness)",
        # "**wording** — class reduced"). Bucketing on the leading keyword is what turns that
        # into a rate; printing the raw strings produces a 60-row table nobody can read and no
        # percentage anyone can quote. The raw cell stays in the CSV for anyone who needs it.
        function bucket(c,   s) {
            s = tolower(c)
            gsub(/[*` ]/, "", s)
            if (s ~ /^blocking/) return "blocking"
            if (s ~ /^wording/) return "wording"
            if (s ~ /^citation/) return "citation"
            if (s ~ /^deferred/) return "deferred"
            if (s ~ /^rejected/) return "rejected"
            if (s == "" || s == "—" || s == "-") return "(unclassed)"
            return "other"
        }
        NR == 1 { next }
        {
            # Re-split on the quoted-field boundary rather than on bare commas: reasons
            # contain commas, so field positions are only reliable via this pattern.
            n = split($0, f, /","/)
            for (i = 1; i <= n; i++) { gsub(/^"|"$/, "", f[i]) }
            kind = f[2]; cls = f[4]; status = f[6]
            if (kind == "ledger") {
                total++
                class_count[bucket(cls)]++
                if (status != "" && status != "open" && status != "needs-reverify") {
                    adjudicated++
                    if (status == "rejected") rejected++
                }
                status_count[status == "" ? "(blank)" : status]++
            } else {
                v_total++
                v[status]++
            }
        }
        END {
            printf "ledger rows: %d\n", total
            for (c in class_count)
                printf "  class %-14s %6d  (%.1f%%)\n", c, class_count[c], 100 * class_count[c] / total
            if (total > 0 && ("blocking" in class_count))
                printf "  non-blocking share: %.1f%%\n", 100 * (total - class_count["blocking"]) / total
            if (adjudicated > 0)
                printf "  rejected %d of %d adjudicated (%.1f%%)\n", rejected, adjudicated, 100 * rejected / adjudicated
            printf "verification limbs: %d\n", v_total
            for (k in v) printf "  %-18s %6d\n", k, v[k]
        }
    ' "$out_file" >&2
fi
