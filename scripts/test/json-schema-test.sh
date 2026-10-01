#!/usr/bin/env bash
# json-schema-test.sh — keyword-level tests for scripts/lib/json-schema.sh,
# the draft-07 subset validator behind validate_policy and
# check-label-docs.sh (go-kure/.github#161). Each supported keyword is shown
# to accept and to refuse; everything outside the subset, and every input
# that cannot be checked, must return 2 rather than a pass.
#
# Usage: json-schema-test.sh [REPO_ROOT]

# shellcheck disable=SC2016 # file-wide: the single-quoted JSON fixtures name the $ref/$schema keywords literally; nothing is meant to expand
set -uo pipefail # deliberately not -e: assertions continue past failures to report all of them

ROOT="${1:-.}"
ROOT="$(cd "$ROOT" && pwd)"

# shellcheck source=scripts/lib/json-schema.sh
source "$ROOT/scripts/lib/json-schema.sh"

failures=0
pass_count=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "PASS: $desc"
        pass_count=$((pass_count + 1))
    else
        echo "FAIL: $desc"
        echo "  expected: $expected"
        echo "  actual:   $actual"
        failures=$((failures + 1))
    fi
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# check SCHEMA DATA -> "rc|first output line"
check() {
    local out rc=0
    printf '%s\n' "$1" >"$work/schema.json"
    out=$(printf '%s' "$2" | json_schema_violations "$work/schema.json") || rc=$?
    printf '%s|%s' "$rc" "$(head -1 <<<"$out")"
}

# ---- type ----
assert_eq "type: a matching type passes" "0|" "$(check '{"type": "string"}' '"x"')"
assert_eq "type: a wrong type is named" "1|(root): expected string, got integer" "$(check '{"type": "string"}' '1')"
assert_eq "type: integer refuses a fraction" "1|(root): expected integer, got number" "$(check '{"type": "integer"}' '1.5')"
assert_eq "type: number accepts an integer" "0|" "$(check '{"type": "number"}' '2')"
assert_eq "type: a list of types accepts any of them" "0|" "$(check '{"type": ["object", "null"]}' 'null')"
assert_eq "type: a list of types refuses the rest" "1|(root): expected object or null, got boolean" "$(check '{"type": ["object", "null"]}' 'false')"
assert_eq "type: boolean is not a string" "1|(root): expected string, got boolean" "$(check '{"type": "string"}' 'true')"

# ---- enum ----
assert_eq "enum: a member passes" "0|" "$(check '{"enum": ["a", "b"]}' '"b"')"
assert_eq "enum: a non-member is named with the choices" '1|(root): "c" is not one of "a", "b"' "$(check '{"enum": ["a", "b"]}' '"c"')"
assert_eq "enum: comparison is by JSON value, not text" '1|(root): "1" is not one of 1' "$(check '{"enum": [1]}' '"1"')"

# ---- properties / required / additionalProperties ----
obj='{"type": "object", "additionalProperties": false, "required": ["a"], "properties": {"a": {"type": "integer"}, "b": {"type": "string"}}}'
assert_eq "object: declared keys of the right type pass" "0|" "$(check "$obj" '{"a": 1, "b": "x"}')"
assert_eq "object: a missing required key is named" '1|(root): missing required key "a"' "$(check "$obj" '{"b": "x"}')"
assert_eq "object: an undeclared key is refused when closed" "1|zz: unknown key" "$(check "$obj" '{"a": 1, "zz": 0}')"
assert_eq "object: a declared key is checked against its schema" "1|b: expected string, got integer" "$(check "$obj" '{"a": 1, "b": 2}')"
assert_eq "object: an open object accepts other keys" "0|" "$(check '{"type": "object", "properties": {"a": {"type": "integer"}}}' '{"zz": 0}')"
assert_eq "object: additionalProperties as a schema checks the other keys" "1|k: expected integer, got string" \
    "$(check '{"type": "object", "additionalProperties": {"type": "integer"}}' '{"k": "v"}')"
assert_eq "object: every violation is reported, not only the first" "2" \
    "$(printf '%s\n' "$obj" >"$work/s.json"; json_schema_violations "$work/s.json" <<<'{"zz": 0, "b": 1}' | grep -vc 'missing required')"

# ---- strings ----
assert_eq "minLength: too short is refused" "1|(root): shorter than 2 character(s)" "$(check '{"type": "string", "minLength": 2}' '"x"')"
assert_eq "maxLength: too long is refused" "1|(root): longer than 2 characters" "$(check '{"type": "string", "maxLength": 2}' '"xyz"')"
assert_eq "maxLength: at the limit passes" "0|" "$(check '{"type": "string", "maxLength": 2}' '"xy"')"
assert_eq "pattern: a match passes" "0|" "$(check '{"type": "string", "pattern": "^#[0-9a-f]{6}$"}' '"#00aaff"')"
assert_eq "pattern: a mismatch is named" '1|(root): "#00aaf" does not match ^#[0-9a-f]{6}$' "$(check '{"type": "string", "pattern": "^#[0-9a-f]{6}$"}' '"#00aaf"')"

# ---- numbers ----
assert_eq "minimum: below is refused" "1|(root): -1 is below the minimum 0" "$(check '{"type": "integer", "minimum": 0}' '-1')"
assert_eq "maximum: above is refused" "1|(root): 11 is above the maximum 10" "$(check '{"type": "integer", "maximum": 10}' '11')"
assert_eq "minimum/maximum: the bounds themselves pass" "0|" "$(check '{"type": "integer", "minimum": 0, "maximum": 0}' '0')"

# ---- arrays ----
assert_eq "items: every item is checked, with its index" "1|[1]: expected string, got integer" "$(check '{"type": "array", "items": {"type": "string"}}' '["a", 2]')"
assert_eq "minItems: an empty list is refused" "1|(root): fewer than 1 item(s)" "$(check '{"type": "array", "minItems": 1}' '[]')"
assert_eq "uniqueItems: a duplicate is refused" "1|(root): items are not unique" "$(check '{"type": "array", "uniqueItems": true}' '["a", "a"]')"
assert_eq "uniqueItems: distinct items pass" "0|" "$(check '{"type": "array", "uniqueItems": true}' '["a", "b"]')"

# ---- $ref / definitions / boolean schemas ----
assert_eq "\$ref: resolves into definitions" "1|x: expected integer, got string" \
    "$(check '{"type": "object", "properties": {"x": {"$ref": "#/definitions/n"}}, "definitions": {"n": {"type": "integer"}}}' '{"x": "1"}')"
assert_eq "\$ref: a recursive definition works" "1|next.next.v: expected integer, got string" \
    "$(check '{"$ref": "#/definitions/node", "definitions": {"node": {"type": "object", "properties": {"v": {"type": "integer"}, "next": {"$ref": "#/definitions/node"}}}}}' '{"next": {"next": {"v": "x"}}}')"
assert_eq "boolean schema: false refuses anything" "1|x: not allowed here" "$(check '{"properties": {"x": false}}' '{"x": 1}')"
assert_eq "boolean schema: true accepts anything" "0|" "$(check 'true' '{"x": [1, {}]}')"
assert_eq "annotations are accepted and ignored" "0|" \
    "$(check '{"$schema": "http://json-schema.org/draft-07/schema#", "$id": "x", "$comment": "c", "title": "t", "description": "d", "type": "string"}' '"x"')"

# ---- paths ----
assert_eq "path: a key that is not an identifier is quoted" '1|a[".github"].b: expected string, got integer' \
    "$(check '{"properties": {"a": {"additionalProperties": {"properties": {"b": {"type": "string"}}}}}}' '{"a": {".github": {"b": 1}}}')"
assert_eq "path: a key with spaces is quoted" '1|["a b"]: expected string, got integer' \
    "$(check '{"additionalProperties": {"type": "string"}}' '{"a b": 1}')"

# ---- what cannot be checked returns 2, never 0 ----
assert_eq "an unsupported keyword is a schema error" "2|schema error: at (root): unsupported keyword(s) anyOf" "$(check '{"anyOf": [{"type": "string"}]}' '"x"')"
assert_eq "an unsupported keyword deep in the schema is reached" "2|schema error: at a: unsupported keyword(s) format" \
    "$(check '{"properties": {"a": {"type": "string", "format": "email"}}}' '{"a": "x"}')"
assert_eq "an unknown type name is a schema error" "2|schema error: at (root): unknown type(s) bool" "$(check '{"type": "bool"}' 'true')"
assert_eq "an unresolvable \$ref is a schema error" '2|schema error: at (root): unresolvable $ref "#/definitions/nope"' "$(check '{"$ref": "#/definitions/nope"}' '1')"
assert_eq "a \$ref outside definitions is a schema error" '2|schema error: at (root): unresolvable $ref "other.json"' "$(check '{"$ref": "other.json"}' '1')"
assert_eq "a \$ref with a sibling keyword is a schema error" '2|schema error: at (root): $ref "#/definitions/n" has sibling keywords' \
    "$(check '{"$ref": "#/definitions/n", "type": "string", "definitions": {"n": {}}}' '"x"')"
assert_eq "a schema that is neither object nor boolean is a schema error" "2|schema error: at x: a schema must be an object or a boolean" \
    "$(check '{"properties": {"x": 1}}' '{"x": 1}')"
assert_eq "data that is not JSON cannot be checked" "2" "$(check '{}' '{not json' | cut -d'|' -f1)"
assert_eq "empty data cannot be checked" "2" "$(check '{}' '' | cut -d'|' -f1)"
assert_eq "two JSON documents cannot be checked" "2" "$(check '{}' '{} {}' | cut -d'|' -f1)"
printf '%s\n' '{not json' >"$work/broken.json"
assert_eq "a schema file that is not JSON cannot be checked" "2" \
    "$(rc=0; json_schema_violations "$work/broken.json" <<<'{}' >/dev/null || rc=$?; echo "$rc")"

# ---- the repo's own files conform to the repo's own schemas ----
assert_eq "standards/labels.json conforms to standards/labels.schema.json" "0" \
    "$(rc=0; json_schema_violations "$ROOT/standards/labels.schema.json" <"$ROOT/standards/labels.json" || rc=$?; echo "$rc")"
assert_eq "the settings policy conforms to its schema" "0" \
    "$(rc=0; yq -oj '.' "$ROOT/governance/repository-settings-policy.yaml" | json_schema_violations "$ROOT/governance/repository-settings-policy.schema.json" || rc=$?; echo "$rc")"

echo
echo "json-schema-test: $pass_count passed, $failures failed"
[ "$failures" -eq 0 ]
