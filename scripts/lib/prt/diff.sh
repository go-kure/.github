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
# for each chunk, in order. Prints the number of chunks written to stdout.
prt_split_diff() {
  local diff_file="$1" max_chars="$2" out_dir="$3"
  local hard_ceiling=$((max_chars * PRT_HARD_CEILING_MULT))
  mkdir -p "$out_dir"

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
  ' "$diff_file" > "$records_file"

  local -a records=()
  mapfile -d $'\0' -t records < "$records_file"
  rm -f "$records_file"

  local chunk_idx=0
  local cur_file
  cur_file="$out_dir/chunk-$(printf '%03d' "$chunk_idx").diff"
  : > "$cur_file"
  local cur_size=0

  new_chunk() {
    chunk_idx=$((chunk_idx + 1))
    cur_file="$out_dir/chunk-$(printf '%03d' "$chunk_idx").diff"
    : > "$cur_file"
    cur_size=0
  }

  local rec rec_size
  for rec in "${records[@]}"; do
    [ -n "$rec" ] || continue
    rec_size=${#rec}

    if [ "$cur_size" -gt 0 ] && [ $((cur_size + rec_size)) -gt "$max_chars" ]; then
      new_chunk
    fi

    if [ "$rec_size" -le "$max_chars" ]; then
      printf '%s\n' "$rec" >> "$cur_file"
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
    ' <<< "$rec" > "$hunks_file"

    local -a hunks=()
    mapfile -d $'\0' -t hunks < "$hunks_file"
    rm -f "$hunks_file"

    local piece_size=${#header}
    printf '%s\n' "$header" >> "$cur_file"
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
        if [ "$piece_size" -gt "${#header}" ]; then new_chunk; printf '%s\n' "$header" >> "$cur_file"; piece_size=${#header}; cur_size=$piece_size; fi
        printf '%s\n' "${hunk:0:hard_ceiling}" >> "$cur_file"
        printf '\n... (hunk truncated at %d chars, exceeds hard ceiling)\n' "$hard_ceiling" >> "$cur_file"
        if command -v prt_mark_incomplete >/dev/null 2>&1; then
          prt_mark_incomplete "diff chunking: a single hunk exceeded the ${hard_ceiling}-char hard ceiling and was truncated"
        fi
        new_chunk
        printf '%s\n' "$header" >> "$cur_file"
        piece_size=${#header}
        cur_size=$piece_size
        continue
      fi

      if [ $((piece_size + hunk_size)) -gt "$max_chars" ] && [ "$piece_size" -gt "${#header}" ]; then
        new_chunk
        printf '%s\n' "$header" >> "$cur_file"
        piece_size=${#header}
        cur_size=$piece_size
      fi

      printf '%s\n' "$hunk" >> "$cur_file"
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
    /^\+\+\+ / {
      f = $2
      sub(/^b\//, "", f)
      cur = (f == "/dev/null") ? "" : f
      next
    }
    /^@@ / {
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
