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
# perform.
#
# Supported keywords: type (a name or a list of names), enum, properties,
# required, additionalProperties (false or a schema), items (one schema),
# minItems, uniqueItems, minLength, maxLength, pattern, minimum, maximum, and
# $ref to "#/definitions/<name>" with no sibling keyword other than an
# annotation (draft-07 ignores $ref's siblings; refusing them keeps a schema
# from appearing to check something it does not). Annotations: $schema, $id, $comment, title, description,
# definitions. Boolean schemas (true/false) are accepted.
#
# Not supported, by design: allOf/anyOf/oneOf/not, patternProperties,
# propertyNames, if/then/else, dependencies, format. draft-07's
# additionalProperties sees only its sibling properties, so combining closed
# sub-schemas with allOf would reject every key of the other half anyway.
#
# Usage: json_schema_violations SCHEMA_FILE < DATA
#   Prints one "<path>: <problem>" line per violation, where <path> is a jq-
#   style path such as github_repos[".github"].security.secret_scanning.
#   Returns 0 when DATA conforms, 1 when it does not, and 2 when the check
#   could not run: the schema uses something outside the subset, a $ref does
#   not resolve, or a file is not JSON.

# shellcheck disable=SC2016 # single-quoted on purpose: a jq program, not shell
JSON_SCHEMA_JQ='
def _fmt:
  if length == 0 then "(root)"
  else reduce .[] as $k ("";
    . + (if ($k | type) == "number" then "[\($k)]"
         elif ($k | test("^[A-Za-z_][A-Za-z0-9_-]*$")) then (if . == "" then $k else "." + $k end)
         else "[\($k | tojson)]" end))
  end;

def _jtype: if type == "number" and . == floor then "integer" else type end;

def _type_ok($t): if $t == "integer" then (type == "number" and . == floor) else type == $t end;

def _known: ["$schema", "$id", "$comment", "title", "description", "definitions", "$ref",
             "type", "enum", "properties", "required", "additionalProperties", "items",
             "minItems", "uniqueItems", "minLength", "maxLength", "pattern", "minimum", "maximum"];

def _v($root; $s; $p):
  . as $x
  | if ($s | type) == "boolean" then
      (if $s then empty else "\($p | _fmt): not allowed here" end)
    elif ($s | type) != "object" then
      "schema error: at \($p | _fmt): a schema must be an object or a boolean"
    elif ($s | keys - _known | length) > 0 then
      "schema error: at \($p | _fmt): unsupported keyword(s) \($s | keys - _known | join(", "))"
    elif ($s | has("$ref")) then
      ($s["$ref"]) as $ref
      | if ($s | keys - ["$ref", "$schema", "$id", "$comment", "title", "description", "definitions"] | length) > 0 then
          "schema error: at \($p | _fmt): $ref \($ref | tojson) has sibling keywords"
        elif ($ref | type) == "string" and ($ref | startswith("#/definitions/"))
             and (($root.definitions // {}) | has($ref | ltrimstr("#/definitions/"))) then
          _v($root; $root.definitions[$ref | ltrimstr("#/definitions/")]; $p)
        else
          "schema error: at \($p | _fmt): unresolvable $ref \($ref | tojson)"
        end
    else
      ($s.type | if . == null then null elif type == "array" then . else [.] end) as $ts
      | if $ts != null and ($ts - ["object", "array", "string", "integer", "number", "boolean", "null"] | length) > 0 then
          "schema error: at \($p | _fmt): unknown type(s) \($ts - ["object", "array", "string", "integer", "number", "boolean", "null"] | join(", "))"
        elif $ts != null and (any($ts[]; . as $t | $x | _type_ok($t)) | not) then
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
             (if ($s | has("pattern")) and ($x | test($s.pattern) | not) then
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

[inputs] as $docs
| if ($docs | length) != 1 then error("expected exactly one JSON document, got \($docs | length)") else . end
| $schema[0] as $s | $docs[0] | _v($s; $s; [])
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
