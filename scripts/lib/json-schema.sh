#!/usr/bin/env bash
# json-schema.sh — a small JSON Schema (draft-07 subset) validator written in
# jq, for the input files a script must refuse before it mutates anything
# (go-kure/.github#161). Sourced; defines json_schema_violations.
#
# Why not a JSON Schema tool: jq is already required everywhere these files
# are read (the runners, every thin consumer of github-settings.sh), and the
# schemas here need only a handful of keywords. The schemas stay standard
# draft-07, so check-jsonschema or an editor reads them with the same meaning.
# The subset is closed: a keyword outside it is a schema error, never
# silently ignored, so a schema cannot claim a check this validator does not
# perform. The whole schema is checked before any data is, so an error in a
# branch the data never reaches (an absent property, an empty list, an unused
# definition) is still an error.
#
# Supported keywords: type (a name or a list of names), enum, properties,
# required, additionalProperties (false or a schema), items (one schema),
# minItems, uniqueItems, minLength, maxLength, pattern, minimum, maximum, and
# $ref to "#/definitions/<name>" with no sibling keyword other than an
# annotation (draft-07 ignores $ref's siblings; refusing them keeps a schema
# from appearing to check something it does not). Annotations: $schema, $id
# (on the root only: a nested $id would scope the $refs under it),
# $comment, title, description, definitions. Boolean schemas (true/false) are
# accepted. Each keyword's value is checked for its draft-07 shape (a numeric
# bound is a number, enum a non-empty list of distinct values, and so on). A
# length or item-count bound must be written as plain digits: jq reads
# 1e-1000 as 0, so 1.0, 1e2 and the like are refused rather than judged by
# their parsed value. For the same reason a data value of type "integer" must
# be written as plain digits.
#
# Not supported, by design: allOf/anyOf/oneOf/not, patternProperties,
# propertyNames, if/then/else, dependencies, format, items as a list, and a
# $ref whose name holds "/", "~" or "%" (JSON Pointer escapes are not decoded,
# so such a reference is refused rather than resolved to the wrong name).
# draft-07's additionalProperties sees only its sibling properties, so
# combining closed sub-schemas with allOf would reject every key of the other
# half anyway.
#
# pattern follows ECMA-262 anchoring: "^" is the start of the string and "$"
# its very end. jq's "$" also matches before a final newline, so a leading "^"
# and a trailing "$" are rewritten to \A and \z before matching, and "^" or "$"
# anywhere else (outside a character class, unescaped) is a schema error.
# So is any construct jq would read differently from ECMA-262: letter and
# digit escapes such as \d (Unicode digits in jq), ".", "(?" groups other
# than "(?:", a quantifier on a quantifier (a**, a*+), an empty class, and "[" or "&"
# inside a class. A brace that does not open {n}, {n,} or {n,m} is a literal
# in both.
#
# Input is JSON only: NaN, Infinity and numbers too large for a double, which
# jq would otherwise read, make the check fail in schema and data alike.
#
# Usage: json_schema_violations SCHEMA_FILE < DATA
#   Prints one "<path>: <problem>" line per violation, where <path> is a jq-
#   style path such as github_repos[".github"].security.secret_scanning.
#   Returns 0 when DATA conforms, 1 when it does not, and 2 when the check
#   could not run: the schema uses something outside the subset, a $ref does
#   not resolve, or a file is not exactly one JSON document.

# shellcheck disable=SC2016 # single-quoted on purpose: a jq program, not shell
JSON_SCHEMA_JQ='
def _fmt:
  if length == 0 then "(root)"
  else reduce .[] as $k ("";
    . + (if ($k | type) == "number" then "[\($k)]"
         elif ($k | test("^[A-Za-z_][A-Za-z0-9_-]*$")) then (if . == "" then $k else "." + $k end)
         else "[\($k | tojson)]" end))
  end;

# An integer is judged as written, plain digits only, like the schema bounds:
# ". == floor" passes 1e-1000, which jq keeps as written in its output.
def _int: type == "number" and (tojson | test("^-?[0-9]+$"));

def _jtype: if _int then "integer" else type end;

def _type_ok($t): if $t == "integer" then _int else type == $t end;

def _types: ["object", "array", "string", "integer", "number", "boolean", "null"];

def _known: ["$schema", "$id", "$comment", "title", "description", "definitions", "$ref",
             "type", "enum", "properties", "required", "additionalProperties", "items",
             "minItems", "uniqueItems", "minLength", "maxLength", "pattern", "minimum", "maximum"];

def _nonfinite: [.. | numbers | select(isnan or isinfinite)] | length > 0;

# The unescaped "^" and "$" of a pattern outside character classes, by index.
def _anchors:
  (explode | map([.] | implode)) as $cs
  | reduce range(0; $cs | length) as $i ({esc: false, cls: false, at: []};
      $cs[$i] as $c
      | if .esc then .esc = false
        elif $c == "\\" then .esc = true
        elif .cls then (if $c == "]" then .cls = false else . end)
        elif $c == "[" then .cls = true
        elif $c == "^" or $c == "$" then .at += [{i: $i, c: $c}]
        else . end)
  | {len: ($cs | length), at};

# The first construct of a pattern whose meaning in jq (Oniguruma) is not its
# ECMA-262 meaning, or null: "\d", "\w", "\s", "\b" and every other letter
# or digit escape (Oniguruma \d matches any Unicode digit), ".", "(?" other
# than "(?:", a quantifier on a quantifier, and, inside a class, "[" (nested sets,
# "[:alpha:]"), "&" ("&&" intersection) and an empty "[]".
def _pattern_unsupported:
  (explode | map([.] | implode)) as $cs
  # q: 0 after an atom, 1 after a quantifier ("*", "+", "?", {n}, {n,} or
  # {n,m}), 2 after a lazy quantifier ("*?"). Only a lazy "?" may follow a
  # quantifier: ECMA-262 refuses a**, a+?+ and a*{2}, where Oniguruma reads
  # possessive or stacked repetition. Any other brace, as in "{name}" or "a}",
  # is a literal atom in both. skip: the index past a {n,m} quantifier.
  | reduce range(0; $cs | length) as $i ({esc: false, cls: false, cstart: -1, q: 0, skip: 0, bad: null};
      $cs[$i] as $c
      | if .bad != null or $i < .skip then .
        elif .esc then (if ($c | test("^[A-Za-z0-9]$")) then .bad = "\\" + $c else . end) | .esc = false | .q = 0
        elif $c == "\\" then .esc = true
        elif .cls then
          if $c == "]" then (if $i == .cstart then .bad = "[]" else .cls = false end)
          elif $c == "^" and $i == .cstart then .cstart = $i + 1
          elif $c == "[" or $c == "&" then .bad = $c + " in a character class"
          else . end
        elif $c == "{" then
          ([$cs[$i:] | add | match("^\\{[0-9]+(,[0-9]*)?\\}")] | first) as $m
          | if $m == null then .q = 0
            elif .q != 0 then .bad = "a quantifier on a quantifier"
            else .skip = $i + $m.length | .q = 1 end
        elif ($c == "*" or $c == "+") and .q != 0 then .bad = "a quantifier on a quantifier"
        elif $c == "?" and .q == 2 then .bad = "a quantifier on a quantifier"
        elif $c == "?" then .q += 1
        elif $c == "*" or $c == "+" then .q = 1
        elif $c == "[" then .cls = true | .cstart = $i + 1 | .q = 0
        elif $c == "." then .bad = "."
        elif $c == "(" and ($cs[$i + 1] // "") == "?" and ($cs[$i + 2] // "") != ":" then .bad = "(?"
        else .q = 0 end)
  | .bad;

def _anchors_ok: _anchors as $a
  | all($a.at[]; (.i == 0 and .c == "^") or (.i == $a.len - 1 and .c == "$"));

# A pattern rewritten for jq with ECMA-262 anchoring (see the header).
def _ecma: _anchors as $a
  | (if any($a.at[]; .i == $a.len - 1 and .c == "$") then .[:-1] + "\\z" else . end)
  | (if any($a.at[]; .i == 0 and .c == "^") then "\\A" + .[1:] else . end);

# Every problem with the schema itself, wherever it sits, as "schema error:" lines.
def _sc($root; $s; $p):
  def _err($m): "schema error: at \($p | _fmt): \($m)";
  if ($s | type) == "boolean" then empty
  elif ($s | type) != "object" then _err("a schema must be an object or a boolean")
  elif ($s | keys - _known | length) > 0 then _err("unsupported keyword(s) \($s | keys - _known | join(", "))")
  else
    (["$schema", "$id", "$comment", "title", "description"][] as $k
     | select(($s | has($k)) and (($s[$k] | type) != "string"))
     | _err("\($k) must be a string")),
    # A nested $id would open its own scope for the $refs under it, which this
    # validator does not track: every $ref resolves against the root.
    (if ($s | has("$id")) and ($p | length) > 0 then
       _err("$id is supported only on the root schema") else empty end),
    (if ($s | has("$ref")) then
       $s["$ref"] as $ref
       | if ($s | keys - ["$ref", "$schema", "$id", "$comment", "title", "description", "definitions"] | length) > 0 then
           _err("$ref \($ref | tojson) has sibling keywords")
         elif ($ref | type) != "string" or ($ref | test("^#/definitions/[^/~%]+$") | not) then
           _err("unsupported $ref \($ref | tojson): only \"#/definitions/<name>\" with no \"/\", \"~\" or \"%\" in the name")
         elif (($root.definitions // {}) | type) != "object"
              or (($root.definitions // {}) | has($ref | ltrimstr("#/definitions/")) | not) then
           _err("unresolvable $ref \($ref | tojson)")
         else empty end
     else empty end),
    (if ($s | has("type")) then
       ($s.type | if type == "array" then . else [.] end) as $ts
       | if ($ts | length) == 0 or any($ts[]; type != "string") or ($ts | unique | length) != ($ts | length) then
           _err("type must be a type name or a non-empty list of distinct type names")
         elif ($ts - _types | length) > 0 then
           _err("unknown type(s) \($ts - _types | join(", "))")
         else empty end
     else empty end),
    (if ($s | has("enum"))
        and ((($s.enum | type) != "array") or ($s.enum | length) == 0
             or ($s.enum | unique | length) != ($s.enum | length)) then
       _err("enum must be a non-empty array of distinct values") else empty end),
    (if ($s | has("required"))
        and ((($s.required | type) != "array") or any($s.required[]; type != "string")
             or ($s.required | unique | length) != ($s.required | length)) then
       _err("required must be an array of distinct strings") else empty end),
    # Judged as written, plain digits only: ". == floor" passes 1e-1000 (see the header).
    (["minItems", "minLength", "maxLength"][] as $k
     | select(($s | has($k)) and ($s[$k] | (type == "number" and (tojson | test("^[0-9]+$"))) | not))
     | _err("\($k) must be a non-negative integer")),
    (["minimum", "maximum"][] as $k
     | select(($s | has($k)) and (($s[$k] | type) != "number"))
     | _err("\($k) must be a number")),
    (if ($s | has("uniqueItems")) and (($s.uniqueItems | type) != "boolean") then
       _err("uniqueItems must be a boolean") else empty end),
    (if ($s | has("pattern")) then
       $s.pattern as $pat
       | if ($pat | type) != "string" then _err("pattern must be a string")
         elif ($pat | _anchors_ok | not) then
           _err("pattern \($pat | tojson): \"^\" or \"$\" anywhere but its very start or end is not supported")
         elif ($pat | _pattern_unsupported) != null then
           _err("pattern \($pat | tojson): \($pat | _pattern_unsupported) is not supported (jq does not give it its ECMA-262 meaning)")
         elif (try ("" | test($pat | _ecma) | false) catch true) then
           _err("pattern \($pat | tojson) does not compile")
         else empty end
     else empty end),
    (["properties", "definitions"][] as $k
     | select($s | has($k))
     | if ($s[$k] | type) != "object" then _err("\($k) must be an object")
       else ($s[$k] | to_entries[] | .key as $n | _sc($root; .value; $p + [$k, $n])) end),
    (if ($s | has("additionalProperties")) then
       _sc($root; $s.additionalProperties; $p + ["additionalProperties"]) else empty end),
    (if ($s | has("items")) then
       (if ($s.items | type) == "array" then _err("items as a list (tuple validation) is not supported")
        else _sc($root; $s.items; $p + ["items"]) end)
     else empty end)
  end;

# The data checked against a schema that _sc has already accepted.
def _v($root; $s; $p):
  . as $x
  | if ($s | type) == "boolean" then
      (if $s then empty else "\($p | _fmt): not allowed here" end)
    elif ($s | has("$ref")) then
      _v($root; $root.definitions[$s["$ref"] | ltrimstr("#/definitions/")]; $p)
    else
      ($s.type | if . == null then null elif type == "array" then . else [.] end) as $ts
      | if $ts != null and (any($ts[]; . as $t | $x | _type_ok($t)) | not) then
          "\($p | _fmt): expected \($ts | join(" or ")), got \($x | _jtype)"
        else
          (if ($s | has("enum")) and (any($s.enum[]; . == $x) | not) then
             "\($p | _fmt): \($x | tojson) is not one of \($s.enum | map(tojson) | join(", "))"
           else empty end),
          (if ($x | type) == "string" then
             (if ($s | has("minLength")) and ($x | length) < $s.minLength then
                "\($p | _fmt): shorter than \($s.minLength) character(s)" else empty end),
             (if ($s | has("maxLength")) and ($x | length) > $s.maxLength then
                "\($p | _fmt): longer than \($s.maxLength) characters" else empty end),
             (if ($s | has("pattern")) and ($x | test($s.pattern | _ecma) | not) then
                "\($p | _fmt): \($x | tojson) does not match \($s.pattern)" else empty end)
           else empty end),
          (if ($x | type) == "number" then
             (if ($s | has("minimum")) and $x < $s.minimum then
                "\($p | _fmt): \($x) is below the minimum \($s.minimum)" else empty end),
             (if ($s | has("maximum")) and $x > $s.maximum then
                "\($p | _fmt): \($x) is above the maximum \($s.maximum)" else empty end)
           else empty end),
          (if ($x | type) == "array" then
             (if ($s | has("minItems")) and ($x | length) < $s.minItems then
                "\($p | _fmt): fewer than \($s.minItems) item(s)" else empty end),
             (if ($s.uniqueItems // false) and ($x | unique | length) < ($x | length) then
                "\($p | _fmt): items are not unique" else empty end),
             (if ($s | has("items")) then
                ($x | to_entries[] | .key as $i | .value | _v($root; $s.items; $p + [$i]))
              else empty end)
           else empty end),
          (if ($x | type) == "object" then
             (($s.required // [])[] as $r
              | if ($x | has($r)) then empty else "\($p | _fmt): missing required key \($r | tojson)" end),
             ($x | to_entries[] | .key as $k | .value as $val
              | if (($s.properties // {}) | has($k)) then
                  ($val | _v($root; $s.properties[$k]; $p + [$k]))
                elif ($s | has("additionalProperties")) then
                  (if $s.additionalProperties == false then "\($p + [$k] | _fmt): unknown key"
                   else ($val | _v($root; $s.additionalProperties; $p + [$k])) end)
                else empty end)
           else empty end)
        end
    end;

($schema | length) as $n
| if $n != 1 then error("the schema file holds \($n) JSON documents, expected exactly one") else . end
| $schema[0] as $s
| if ($s | _nonfinite) then error("the schema file holds NaN, Infinity or a number too large for a double, which is not JSON") else . end
| [_sc($s; $s; [])] as $schema_errors
| if ($schema_errors | length) > 0 then $schema_errors[]
  else
    [inputs] as $docs
    | if ($docs | length) != 1 then error("expected exactly one JSON document, got \($docs | length)") else . end
    | if ($docs[0] | _nonfinite) then error("the input holds NaN, Infinity or a number too large for a double, which is not JSON") else . end
    | $docs[0] | _v($s; $s; [])
  end
'

json_schema_violations() {
    local schema_file="$1" out rc=0
    out=$(jq -rn --slurpfile schema "$schema_file" "$JSON_SCHEMA_JQ" 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
        printf 'schema check could not run: %s\n' "$out"
        return 2
    fi
    [ -z "$out" ] && return 0
    printf '%s\n' "$out"
    if grep -q '^schema error: ' <<<"$out"; then
        return 2
    fi
    return 1
}
