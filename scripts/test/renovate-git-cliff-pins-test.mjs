#!/usr/bin/env node
// Asserts the git-cliff pin lives where Renovate can move it, and that one bump
// moves every site (go-kure/.github#370).
//
// Runs the customManagers regex from renovate.json over the real files, the way
// Renovate does (file pattern first, then each matchString), and checks:
//   - mise.toml, release.yml and release-publish.yml each match exactly once,
//     with depName orhun/git-cliff, datasource github-releases and one value;
//   - ci.yml matches nothing, because it reads the pin from mise.toml and carries
//     no literal of its own (a literal there would be a second source of truth).
// Two controls prove the regex can match at all and can refuse: a made-up pin
// line in each of the two spellings it must accept, and the same line without
// the `# renovate:` comment.
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

const sites = ["mise.toml", ".github/workflows/release.yml", ".github/workflows/release-publish.yml"];
const values = new Set();
for (const rel of sites) {
  check(appliesTo(rel), `${rel}: the manager's file pattern selects it`);
  const found = extract(readFileSync(join(root, rel), "utf8"));
  check(found.length === 1, `${rel}: exactly one pin matches (found ${found.length})`);
  const hit = found[0] ?? {};
  check(hit.depName === "orhun/git-cliff", `${rel}: depName is orhun/git-cliff (got ${hit.depName})`);
  check(hit.datasource === "github-releases", `${rel}: datasource is github-releases (got ${hit.datasource})`);
  values.add(hit.currentValue);
}
check(values.size === 1, `every site pins one version (got ${[...values].join(", ")})`);

const ci = ".github/workflows/ci.yml";
check(extract(readFileSync(join(root, ci), "utf8")).length === 0, `${ci}: no pin literal (it reads the pin from mise.toml)`);

// Controls.
const header = "# renovate: datasource=github-releases depName=orhun/git-cliff\n";
for (const line of ['CLIFF_VERSION="9.9.9"', '  CLIFF_VERSION="9.9.9"', 'GIT_CLIFF_VERSION = "9.9.9"']) {
  const found = extract(header + line + "\n");
  check(found.length === 1 && found[0].currentValue === "9.9.9", `control: [${line}] is read as 9.9.9`);
  check(extract(line + "\n").length === 0, `control: [${line}] without its renovate comment is not a pin`);
}

console.log(`renovate-git-cliff-pins-test: passed ${passed}, failed ${failures} (config ${relative(process.cwd(), configPath) || "renovate.json"})`);
process.exit(failures === 0 ? 0 : 1);
