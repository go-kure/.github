#!/usr/bin/env node
// Asserts the git-cliff pin lives where Renovate can move it, and that it is the
// only place the version is written (go-kure/.github#390).
//
// Runs the customManagers regex from renovate.json over the real files, the way
// Renovate does (file pattern first, then each matchString), and checks:
//   - mise.toml matches exactly once, with depName orhun/git-cliff, datasource
//     github-releases and a value;
//   - ci.yml, release.yml and release-publish.yml are not selected by the file
//     pattern and match nothing, because install-git-cliff.sh reads the pin from
//     mise.toml and a literal in a workflow would be a second source of truth.
// Controls prove the regex can match at all and can refuse: a made-up pin line
// must be read, the same line without the `# renovate:` comment must not be, and
// the old workflow spellings (a CLIFF_VERSION="x" line, a `version: "x"` input)
// must not be read as a pin.
//
// Usage: node renovate-git-cliff-pins-test.mjs [renovate.json]   (run from the repo root)

import { readFileSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";

const configPath = resolve(process.argv[2] ?? "renovate.json");
const root = dirname(configPath);
const config = JSON.parse(readFileSync(configPath, "utf8"));

let failures = 0;
let passed = 0;
function check(ok, desc) {
  if (ok) {
    passed += 1;
  } else {
    failures += 1;
    console.error(`FAIL: ${desc}`);
  }
}

const managers = (config.customManagers ?? []).filter((m) => JSON.stringify(m).includes("CLIFF_VERSION"));
check(managers.length === 1, `exactly one customManagers entry names CLIFF_VERSION (found ${managers.length})`);
const manager = managers[0] ?? { managerFilePatterns: [], matchStrings: [] };

// Renovate writes a regex pattern as "/.../"; a plain string is a glob, which
// this entry does not use.
const patterns = manager.managerFilePatterns.map((p) => {
  const m = /^\/(.*)\/$/.exec(p);
  check(m !== null, `file pattern ${p} is a /regex/`);
  return new RegExp(m ? m[1] : "$^");
});

function appliesTo(rel) {
  return patterns.some((re) => re.test(rel));
}

function extract(text) {
  const found = [];
  for (const s of manager.matchStrings) {
    for (const m of text.matchAll(new RegExp(s, "g"))) {
      found.push({ ...m.groups });
    }
  }
  return found;
}

const site = "mise.toml";
check(appliesTo(site), `${site}: the manager's file pattern selects it`);
const found = extract(readFileSync(join(root, site), "utf8"));
check(found.length === 1, `${site}: exactly one pin matches (found ${found.length})`);
const hit = found[0] ?? {};
check(hit.depName === "orhun/git-cliff", `${site}: depName is orhun/git-cliff (got ${hit.depName})`);
check(hit.datasource === "github-releases", `${site}: datasource is github-releases (got ${hit.datasource})`);
check(/^\d+\.\d+\.\d+$/.test(hit.currentValue ?? ""), `${site}: the pin is X.Y.Z (got ${hit.currentValue})`);

for (const rel of [".github/workflows/ci.yml", ".github/workflows/release.yml", ".github/workflows/release-publish.yml"]) {
  check(!appliesTo(rel), `${rel}: the file pattern does not select it (the installer reads mise.toml)`);
  check(extract(readFileSync(join(root, rel), "utf8")).length === 0, `${rel}: no pin literal`);
}

// Controls.
const header = "# renovate: datasource=github-releases depName=orhun/git-cliff\n";
const pin = 'GIT_CLIFF_VERSION = "9.9.9"';
const read = extract(header + pin + "\n");
check(read.length === 1 && read[0].currentValue === "9.9.9", `control: [${pin}] is read as 9.9.9`);
check(extract(pin + "\n").length === 0, `control: [${pin}] without its renovate comment is not a pin`);
for (const line of ['CLIFF_VERSION="9.9.9"', '  CLIFF_VERSION="9.9.9"', 'version: "9.9.9"']) {
  check(extract(header + line + "\n").length === 0, `control: [${line}] is not a pin any more`);
}

console.log(`renovate-git-cliff-pins-test: passed ${passed}, failed ${failures} (config ${relative(process.cwd(), configPath) || "renovate.json"})`);
process.exit(failures === 0 ? 0 : 1);
