#!/usr/bin/env bash
# diff.sh — chunk a unified diff for the model, and build the commentable-
# line index used for hybrid anchoring.
#
# Chunking splits on file boundaries first (pack whole files into chunks up
# to a soft char limit), hunk boundaries second (a file too big for one
# chunk alone splits at `@@` boundaries), never mid-hunk. Every chunk that
# starts mid-file gets a REGENERATED file header (`diff --git`/`index`/
# `---`/`+++`) so the model always sees hunks with file attribution. A
# single hunk that still exceeds a hard ceiling (4x the soft limit) is
# truncated as a last resort — the only surviving truncation path — and
# marks REVIEW_INCOMPLETE via prt_mark_incomplete (state.sh must be sourced
# first by the caller).
#
# The commentable-line index is built from the FULL diff, not per chunk, so
# hybrid-anchor verification is correct even if the model misattributes a
# finding to the wrong chunk.

set -uo pipefail

PRT_HARD_CEILING_MULT=4

# prt_split_diff DIFF_FILE MAX_CHARS OUT_DIR — writes OUT_DIR/chunk-NNN.diff
# for each chunk, in order. Prints the number of chunks written to stdout,
# ONLY on success — returns 1 (no stdout) if any write failed. A caller
# capturing this via `$(...)` must check the command substitution's own exit
# status ($? immediately after the assignment), not just parse stdout — a
# swallowed write failure here must not surface as a plausible-looking
# zero/short chunk count.
prt_split_diff() {
  local diff_file="$1" max_chars="$2" out_dir="$3"
  local hard_ceiling=$((max_chars * PRT_HARD_CEILING_MULT))
  local write_failed=0
  mkdir -p "$out_dir" || write_failed=1               # :28

  # Split into per-file records at `diff --git` boundaries. NUL-separated so
  # a record's own content (which may contain anything) can never be
  # mistaken for the separator. `printf "%c", 0` — not `\x00`, which is a
  # gawk-only printf escape; mawk (the default /usr/bin/awk on GitHub's
  # Ubuntu runners) silently drops it and everything after, collapsing every
  # record into one (caught via CI-only chunking test failures — passed
  # under this sandbox's gawk, failed under the runner's mawk).
  local records_file="$out_dir/.records"
  awk '
    /^diff --git / { if (n++) printf "%c", 0; }
    { print }
  ' "$diff_file" > "$records_file" || write_failed=1   # :41

  local -a records=()
  mapfile -d $'\0' -t records < "$records_file"
  rm -f "$records_file"

  local chunk_idx=0
  local cur_file
  cur_file="$out_dir/chunk-$(printf '%03d' "$chunk_idx").diff"
  : > "$cur_file" || write_failed=1                    # :50
  local cur_size=0

  new_chunk() {
    chunk_idx=$((chunk_idx + 1))
    cur_file="$out_dir/chunk-$(printf '%03d' "$chunk_idx").diff"
    : > "$cur_file" || write_failed=1                  # :56
    cur_size=0
  }

  # Covers every `printf '%s\n' "$X" >> "$cur_file"` site — :70, :92, the
  # compound-statement site (below), :106, :112, :120, :125.
  _prt_chunk_write() { printf '%s\n' "$1" >> "$cur_file" || write_failed=1; }

  local rec rec_size
  for rec in "${records[@]}"; do
    [ -n "$rec" ] || continue
    rec_size=${#rec}

    if [ "$cur_size" -gt 0 ] && [ $((cur_size + rec_size)) -gt "$max_chars" ]; then
      new_chunk
    fi

    if [ "$rec_size" -le "$max_chars" ]; then
      _prt_chunk_write "$rec"                          # :70
      cur_size=$((cur_size + rec_size))
      continue
    fi

    # This one file's diff alone exceeds the soft limit: split at `@@ `
    # hunk boundaries, regenerating the file header on every piece.
    if [ "$cur_size" -gt 0 ]; then new_chunk; fi

    local header hunks_file
    header="$(awk '/^@@ /{exit} {print}' <<< "$rec")"
    hunks_file="$out_dir/.hunks"
    awk '
      /^@@ / { if (n++) printf "%c", 0; }
      n > 0 { print }
    ' <<< "$rec" > "$hunks_file" || write_failed=1      # :85

    local -a hunks=()
    mapfile -d $'\0' -t hunks < "$hunks_file"
    rm -f "$hunks_file"

    local piece_size=${#header}
    _prt_chunk_write "$header"                           # :92
    cur_size=$piece_size

    local hunk hunk_size
    for hunk in "${hunks[@]}"; do
      [ -n "$hunk" ] || continue
      hunk_size=${#hunk}

      if [ "$hunk_size" -gt "$hard_ceiling" ]; then
        # Last-resort truncation: this single hunk alone blows the hard
        # ceiling. Truncate its body and mark the run incomplete — a
        # narrower miss than truncating the whole diff blind, and the only
        # path that still sets REVIEW_INCOMPLETE from this module.
        if [ "$piece_size" -gt "${#header}" ]; then new_chunk; _prt_chunk_write "$header"; piece_size=${#header}; cur_size=$piece_size; fi  # :105
        _prt_chunk_write "${hunk:0:hard_ceiling}"        # :106
        # :107 does not fit _prt_chunk_write's '%s\n' "$X" shape (two-arg
        # printf, embedded %d) — guard it directly instead of forcing it
        # through the helper.
        printf '\n... (hunk truncated at %d chars, exceeds hard ceiling)\n' "$hard_ceiling" >> "$cur_file" || write_failed=1   # :107
        if command -v prt_mark_incomplete >/dev/null 2>&1; then
          prt_mark_incomplete "diff chunking: a single hunk exceeded the ${hard_ceiling}-char hard ceiling and was truncated"
        fi
        new_chunk
        _prt_chunk_write "$header"                       # :112
        piece_size=${#header}
        cur_size=$piece_size
        continue
      fi

      if [ $((piece_size + hunk_size)) -gt "$max_chars" ] && [ "$piece_size" -gt "${#header}" ]; then
        new_chunk
        _prt_chunk_write "$header"                       # :120
        piece_size=${#header}
        cur_size=$piece_size
      fi

      _prt_chunk_write "$hunk"                            # :125
      piece_size=$((piece_size + hunk_size))
      cur_size=$piece_size
    done
  done

  # Drop a trailing empty chunk (created by new_chunk but never written to,
  # e.g. an empty input diff).
  if [ ! -s "$cur_file" ]; then
    rm -f "$cur_file"
    chunk_idx=$((chunk_idx - 1))
  fi

  if [ "$write_failed" = 1 ]; then
    if command -v prt_mark_incomplete >/dev/null 2>&1; then
      prt_mark_incomplete "prt_split_diff: one or more chunk writes failed (disk full? permissions?) — chunking did not complete, chunk count below is not trustworthy"
    fi
    return 1
  fi
  echo $((chunk_idx + 1))
}

# prt_build_line_index DIFF_FILE — prints a JSON object {"path": [line, ...]}
# of every "commentable" new-file line: added (+) and context ( ) lines,
# which have a real position on the right-hand side GitHub can anchor a
# review comment to. Removed (-) lines have no right-side line number and
# are never commentable. A file whose new path is /dev/null (deleted) is
# skipped entirely — it has no right-side lines at all, consistent with
# falling back to a file-level (subject_type: file) thread for it instead.
prt_build_line_index() {
  local diff_file="$1"
  awk '
    # The header rules are position-gated, not pattern-gated. Inside a hunk
    # every body line carries a +/- prefix, so adding a line whose own text
    # begins "++ " arrives as "+++ ..." — a pattern-only match reassigns cur
    # mid-file, indexing the rest of that file under a path that does not
    # exist and silently costing every finding there its inline anchor.
    # in_hunk closes it: headers precede the first @@ of a file, body lines
    # follow it, and `diff --git` reopens the header region. Same shape, and
    # the same reasoning written out at length, as removed_lines in
    # scripts/eval/build-gold.sh (go-kure/.github#163).
    /^diff --git / { in_hunk = 0; cur = ""; next }
    !in_hunk && /^\+\+\+ / {
      f = $2
      sub(/^b\//, "", f)
      cur = (f == "/dev/null") ? "" : f
      next
    }
    /^@@ / {
      # Set before the cur=="" bail: a deleted file has cur=="" from its
      # `+++ /dev/null`, and bailing first would leave its header region open
      # across the whole hunk.
      in_hunk = 1
      if (cur == "") next
      # @@ -a,b +c,d @@ ... — take the first "+<digits>" as the new-file
      # start line.
      if (match($0, /\+[0-9]+/)) {
        newln = substr($0, RSTART + 1, RLENGTH - 1) + 0
      }
      next
    }
    cur == "" { next }
    /^\+/ { print cur "\t" newln; newln++; next }
    /^ /  { print cur "\t" newln; newln++; next }
    /^-/  { next }
  ' "$diff_file" | jq -R -s '
    split("\n")
    | map(select(length > 0) | split("\t") | {file: .[0], line: (.[1] | tonumber)})
    | group_by(.file)
    | map({key: .[0].file, value: [.[].line]})
    | from_entries
  '
}

# prt_diff_files DIFF_FILE — prints each file a unified diff touches, one per
# line, in diff order, once each (go-kure/.github#173: the file lists a
# chunked review is told about). The path is the new side (`+++ b/`), or the
# old side (`--- a/`) for a deleted file. A record with no `---`/`+++` pair
# takes, in order, its `rename to`/`copy to` line (a pure rename or copy), the
# new side of its `Binary files … differ` line, or its `diff --git` line,
# split where both halves name the same path so a name with spaces survives.
# Git C-quotes a path holding `"`, `\`, a control character or a non-ASCII
# byte (`"b/quote\"name.go"`, octal `\303\251`); such a path is decoded to its
# bytes, except that one holding a control character (a newline would split
# the one-per-line list) is printed in its quoted form, prefix removed. Git
# ends an unquoted `---`/`+++` path that holds a space with a tab; it is
# dropped. Header lines are position-gated as in prt_build_line_index: a body
# line that reads `+++ x` inside a hunk is never a header.
prt_diff_files() {
  LC_ALL=C awk '
    # name(tok, pfx): the path at the start of tok, with the side prefix pfx
    # ("a/", "b/" or "") removed. Sets REST to whatever follows the path when
    # it is quoted.
    function name(tok, pfx,   n, i, c, k, o, out, ctrl, raw) {
      REST = ""
      if (substr(tok, 1, 1) != "\"") {
        sub(/\t$/, "", tok)
        if (pfx != "" && substr(tok, 1, length(pfx)) == pfx) tok = substr(tok, length(pfx) + 1)
        return tok
      }
      out = ""; ctrl = 0; n = length(tok)
      for (i = 2; i <= n; i++) {
        c = substr(tok, i, 1)
        if (c == "\"") break
        if (c != "\\") { out = out c; continue }
        i++; c = substr(tok, i, 1)
        if (c ~ /[0-7]/) {
          o = 0
          for (k = 0; k < 3 && substr(tok, i, 1) ~ /[0-7]/; k++) { o = o * 8 + substr(tok, i, 1); i++ }
          i--
          if (o < 32 || o == 127) ctrl = 1
          else out = out sprintf("%c", o)
        } else if (c ~ /[abfnrtv]/) {
          ctrl = 1
        } else {
          out = out c
        }
      }
      if (i > n) return tok
      raw = substr(tok, 1, i); REST = substr(tok, i + 1)
      if (ctrl) {
        if (pfx != "" && substr(raw, 2, length(pfx)) == pfx) raw = "\"" substr(raw, length(pfx) + 2)
        return raw
      }
      if (pfx != "" && substr(out, 1, length(pfx)) == pfx) out = substr(out, length(pfx) + 1)
      return out
    }
    # gitline(rest): the new-side path of a `diff --git` line.
    function gitline(rest,   n, h, i) {
      if (substr(rest, 1, 1) == "\"") { name(rest, "a/"); rest = REST; sub(/^ /, "", rest); return name(rest, "b/") }
      i = index(rest, " \"b/")
      if (i > 0) return name(substr(rest, i + 1), "b/")
      n = length(rest)
      if (n > 5 && (n - 5) % 2 == 0) {
        h = (n - 5) / 2
        if (substr(rest, 1, 2) == "a/" && substr(rest, h + 3, 3) == " b/" && substr(rest, 3, h) == substr(rest, h + 6))
          return substr(rest, h + 6)
      }
      sub(/.* b\//, "", rest)
      return rest
    }
    # binline(s): the new side (old side if the new is /dev/null) of
    # `Binary files A and B differ`, given s = "A and B".
    # An unquoted pair is split where both halves name the same path, else at
    # the last " and " that a new side (b/, "b/ or /dev/null) follows.
    function binline(s,   a, b, i, j, n, h, off) {
      n = length(s)
      if (substr(s, 1, 1) == "\"") { a = name(s, "a/"); b = REST; sub(/^ and /, "", b) }
      else if (substr(s, 1, 14) == "/dev/null and ") { a = "/dev/null"; b = substr(s, 15) }
      else if (n > 9 && (n - 9) % 2 == 0 && substr(s, 1, 2) == "a/" && substr(s, (n - 9) / 2 + 3, 7) == " and b/" && substr(s, 3, (n - 9) / 2) == substr(s, (n - 9) / 2 + 10)) {
        h = (n - 9) / 2; a = substr(s, 1, h + 2); b = substr(s, h + 8)
      }
      else {
        i = 0; off = 0
        while ((j = index(substr(s, off + 1), " and ")) > 0) {
          j += off
          if (substr(s, j + 5, 2) == "b/" || substr(s, j + 5, 3) == "\"b/" || substr(s, j + 5) == "/dev/null") i = j
          off = j
        }
        if (i == 0) return ""
        a = substr(s, 1, i - 1); b = substr(s, i + 5)
      }
      if (b != "/dev/null") return name(b, "b/")
      if (substr(s, 1, 1) == "\"") return a
      return name(a, "a/")
    }
    function emit(p) { if (p != "" && !(p in seen)) { seen[p] = 1; print p } done = 1 }
    function flush() { if (have && !done) emit(ren != "" ? ren : (bin != "" ? bin : fallback)) }
    /^diff --git / {
      flush()
      have = 1; done = 0; in_hunk = 0; minus = ""; ren = ""; bin = ""
      fallback = gitline(substr($0, 12))
      next
    }
    in_hunk { next }
    /^(rename|copy) to / { ren = name(substr($0, index($0, " to ") + 4), ""); next }
    /^Binary files .* differ$/ { bin = binline(substr($0, 14, length($0) - 20)); next }
    /^--- / { minus = substr($0, 5); if (minus != "/dev/null") minus = name(minus, "a/"); next }
    /^\+\+\+ / {
      p = substr($0, 5)
      if (p == "/dev/null") p = minus; else p = name(p, "b/")
      if (p != "/dev/null") emit(p)
      next
    }
    /^@@ / { in_hunk = 1; next }
    END { flush() }
  ' "$1"
}
