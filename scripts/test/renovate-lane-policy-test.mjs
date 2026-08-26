#!/usr/bin/env node
// Asserts every Renovate PR carries exactly one lane label: "unattended"
// (Renovate merges it itself) or "needs-human" (blocked on a review). See
// go-kure/.github#87.
//
// Three checks:
//  1. Outcome — run renovate's own package-rules resolver (applyPackageRules)
//     over a matrix of representative dependency-update paths, one per
//     packageRules entry, and assert the resolved label set contains exactly
//     one lane. A case may also set `expectDashboardApproval` to assert
//     dependencyDashboardApproval directly (opt-in on key presence, not on
//     the value — see the comparison below for why). Also asserts every
//     packageRules index is exercised, so a new rule with no matrix case
//     fails loudly instead of going unexercised — and, separately, that
//     every hand-declared ruleIndices entry actually matches that case's
//     input (via renovate's own per-rule matcher pipeline), so inserting a
//     rule mid-array and silently shifting every later index fails loudly
//     too instead of passing coverage vacuously.
//  2. Structural — no rule may set a lane via addLabels (renovate unions
//     addLabels across every matching rule and a later rule can never remove
//     it, so a rule could advertise "this will automerge" and a later
//     automerge:false rule would leave the label in place regardless); every
//     automerge:true rule must set labels:[...,"unattended"]; every
//     automerge:false rule must set labels:[...,"needs-human"].
//  3. Vulnerability path — the top-level `vulnerabilityAlerts` block is
//     invisible to checks 1/2: renovate never puts it in packageRules, it
//     injects a synthetic rule at fetch time
//     (renovate/lib/workers/repository/process/vulnerabilities.ts,
//     vulnerabilityToPackageRules()) shaped
//     `{ matchDatasources, matchPackageNames, isVulnerabilityAlert: true,
//     force: {...vulnerabilityAlerts} }`. `force` wins over every earlier
//     rule (renovate/lib/util/package-rules/index.ts), so this is the one
//     path in the whole preset that can silently blow the exactly-one-lane
//     invariant or reintroduce a review gate a CVE fix must bypass — assert
//     both, using the same synthetic-rule shape a real run constructs.
//
// Usage: node scripts/test/renovate-lane-policy-test.mjs [presetPath] [renovateModuleEntry]
//   presetPath           default: renovate/shared.json
//   renovateModuleEntry  path to renovate's package-rules/index.js. Omit to
//                        resolve the bare specifier "renovate/dist/util/
//                        package-rules/index.js" from this script's own
//                        node_modules ancestry (works when renovate is
//                        installed as a normal dependency of the invoking
//                        project); pass an explicit path when renovate was
//                        installed elsewhere (CI and `mise run test` install
//                        it into .renovate-lane-test — see
//                        .github/workflows/ci.yml's test job and
//                        mise.toml's test task).

import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const [, , presetPathArg, moduleEntryArg] = process.argv;
const presetPath = presetPathArg ?? "renovate/shared.json";
const moduleSpecifier = moduleEntryArg
  ? pathToFileURL(moduleEntryArg).href
  : "renovate/dist/util/package-rules/index.js";

const { applyPackageRules } = await import(moduleSpecifier);
const preset = JSON.parse(readFileSync(presetPath, "utf8"));

// vulnerabilityAlerts is `mergeable: true`, so a real run merges the block
// this preset supplies onto renovate's own default object for it (e.g.
// dependencyDashboardApproval: false, prCreation: "immediate") before ever
// reaching applyPackageRules — a rule the CVE fix must bypass is bypassed
// via that default, not via anything this preset writes. Pull the default
// from the installed renovate package itself (config/options/index.js,
// which sits next to package-rules/index.js under dist/) rather than
// hardcoding a copy that would silently drift from whatever renovate
// version CI actually installs.
const optionsModuleSpecifier = moduleSpecifier.replace(
  /util\/package-rules\/index\.js$/,
  "config/options/index.js",
);
const { getOptions } = await import(optionsModuleSpecifier);
const vulnerabilityAlertsOption = getOptions().find(
  (o) => o.name === "vulnerabilityAlerts",
);
if (!vulnerabilityAlertsOption) {
  console.error(
    `FATAL: no "vulnerabilityAlerts" option found via ${optionsModuleSpecifier} — ` +
      "the installed renovate version may have renamed or removed it; check VULN_MATRIX below still applies.",
  );
  process.exit(1);
}
const resolvedVulnerabilityAlerts = {
  ...vulnerabilityAlertsOption.default,
  ...preset.vulnerabilityAlerts,
};

// Same sibling-path trick as optionsModuleSpecifier above: matchers.js sits next to
// package-rules/index.js under dist/. Used below to prove each matrix case's hand-declared
// ruleIndices actually match that case's input, not merely that the index falls inside
// [0, packageRules.length) — see the coverage loop's own comment for why membership alone
// doesn't catch a mid-array insert shifting every later index.
const matchersModuleSpecifier = moduleSpecifier.replace(
  /util\/package-rules\/index\.js$/,
  "util/package-rules/matchers.js",
);
const { default: matchers } = await import(matchersModuleSpecifier);

// Mirrors renovate's own (unexported) matchesRule from package-rules/index.js: run every
// matcher in declaration order, treating an explicit falsy result as "no match" and
// null/undefined as "this matcher doesn't apply to this rule, keep checking the rest".
async function matchesRule(inputConfig, packageRule) {
  for (const matcher of matchers) {
    const isMatch = await matcher.matches(inputConfig, packageRule);
    if (isMatch === null || isMatch === undefined) continue;
    if (!isMatch) return false;
  }
  return true;
}

const LANES = ["unattended", "needs-human"];

// Each case exercises one or more packageRules indices (0-based, matching
// renovate/shared.json's array order) with the input fields renovate's
// matchers actually read: matchManagers reads `manager`, matchUpdateTypes
// reads `updateType`, matchDepNames reads `depName`, matchPackageNames reads
// `packageName` ONLY — not `depName` — so this harness must default
// packageName from depName itself, the same way renovate does before rule
// resolution in a real run. Omitting that default would silently skip every
// matchPackageNames rule and pass for the wrong reason.
const MATRIX = [
  { name: "mise toolchain minor (e.g. hugo)", ruleIndices: [0, 12], input: { manager: "mise", updateType: "minor", depName: "hugo" }, expect: "unattended" },
  { name: "mise toolchain patch", ruleIndices: [0, 12], input: { manager: "mise", updateType: "patch", depName: "yq" }, expect: "unattended" },
  { name: "mise toolchain digest", ruleIndices: [0, 12], input: { manager: "mise", updateType: "digest", depName: "hugo" }, expect: "unattended" },
  { name: "mise toolchain major (excluded from the automerge group)", ruleIndices: [11], input: { manager: "mise", updateType: "major", depName: "hugo" }, expect: "needs-human" },
  { name: "go itself via mise (dashboard-gated, never automerged)", ruleIndices: [9], input: { manager: "mise", updateType: "minor", depName: "go" }, expect: "needs-human" },
  { name: "go itself via gomod (dashboard-gated, never automerged)", ruleIndices: [9], input: { manager: "gomod", updateType: "patch", depName: "go", packageName: "go" }, expect: "needs-human" },
  { name: "golang dockerfile tag (dashboard-gated, never automerged)", ruleIndices: [10], input: { manager: "dockerfile", updateType: "minor", depName: "golang", packageName: "golang" }, expect: "needs-human" },
  { name: "gomod minor, kubernetes (no automerge rule matches minor)", ruleIndices: [1, 3], input: { manager: "gomod", updateType: "minor", depName: "k8s.io/api", packageName: "k8s.io/api" }, expect: "needs-human" },
  { name: "gomod patch, kubernetes (automerges)", ruleIndices: [2, 3, 13], input: { manager: "gomod", updateType: "patch", depName: "k8s.io/api", packageName: "k8s.io/api" }, expect: "unattended" },
  { name: "gomod digest, sigs.k8s.io (automerges)", ruleIndices: [2, 4, 13], input: { manager: "gomod", updateType: "digest", depName: "sigs.k8s.io/controller-runtime", packageName: "sigs.k8s.io/controller-runtime" }, expect: "unattended" },
  { name: "gomod patch, fluxcd (automerges)", ruleIndices: [2, 5, 13], input: { manager: "gomod", updateType: "patch", depName: "github.com/fluxcd/pkg/oci", packageName: "github.com/fluxcd/pkg/oci" }, expect: "unattended" },
  { name: "gomod patch, cloudnative-pg (automerges)", ruleIndices: [2, 6, 13], input: { manager: "gomod", updateType: "patch", depName: "github.com/cloudnative-pg/machinery", packageName: "github.com/cloudnative-pg/machinery" }, expect: "unattended" },
  // Deliberately does NOT declare 13 here: rule 13's own matchPackageNames excludes
  // github.com/go-kure/**, so it never matches this case — that exclusion is the point being
  // proven (needs-human survives despite sitting right next to the automerge rule). Rule 13's
  // coverage comes from the four automerge cases below that it actually matches.
  { name: "gomod patch, first-party go-kure (never automerged)", ruleIndices: [2, 7], input: { manager: "gomod", updateType: "patch", depName: "github.com/go-kure/kure", packageName: "github.com/go-kure/kure" }, expect: "needs-human" },
  { name: "gomod major, any dep (dashboard-gated, never automerged)", ruleIndices: [11], input: { manager: "gomod", updateType: "major", depName: "github.com/some/other", packageName: "github.com/some/other" }, expect: "needs-human", expectDashboardApproval: true },
  { name: "github-actions bump (never automerged)", ruleIndices: [8], input: { manager: "github-actions", updateType: "minor", depName: "actions/checkout", packageName: "actions/checkout" }, expect: "needs-human" },
  { name: "npm major (dashboard-gated, never automerged)", ruleIndices: [11], input: { manager: "npm", updateType: "major", depName: "some-pkg", packageName: "some-pkg" }, expect: "needs-human" },
  { name: "dockerfile dep matching no groupRule at all (top-level default)", ruleIndices: [], input: { manager: "dockerfile", updateType: "minor", depName: "alpine", packageName: "alpine" }, expect: "needs-human", expectDashboardApproval: false },
  // customManagers (regex/jsonata) entries report here as "custom.<customType>" (renovate's
  // ManagersMatcher qualifies the config.manager value at match time), never the bare type name
  // the entry's own config carries. These three cases prove the fix (go-kure/.github#87's own
  // history closed exactly this hole): a custom-managed major hits the general gate (rule 11); a
  // custom-managed non-major hits neither gate; and a custom-managed dependency literally named
  // "go" is caught by the dedicated Go rule (rule 9), not the general gate, since that rule alone
  // still carries the allowedVersions ceiling and gates go's non-major bumps too.
  { name: "custom-manager major (dashboard-gated)", ruleIndices: [11], input: { manager: "regex", updateType: "major", depName: "golangci-lint", packageName: "golangci/golangci-lint" }, expect: "needs-human", expectDashboardApproval: true },
  { name: "custom-manager minor (no gate, no automerge)", ruleIndices: [], input: { manager: "regex", updateType: "minor", depName: "git-cliff", packageName: "orhun/git-cliff" }, expect: "needs-human", expectDashboardApproval: false },
  // updateType is "minor", not "major": on a major this case would pass even with rule 9's
  // custom.* left unfixed, since rule 11 (the general gate, matchUpdateTypes:["major"]) already
  // covers a custom-managed go major once its own !go exclusion is dropped. A minor isolates
  // rule 9 — rule 11 never matches a non-major update at all — so this case actually requires
  // rule 9's own matchManagers widening, not just rule 11's.
  { name: "custom-manager depName go, minor (dedicated Go rule only — general gate never matches non-major)", ruleIndices: [9], input: { manager: "regex", updateType: "minor", depName: "go", packageName: "golang.org/dl" }, expect: "needs-human", expectDashboardApproval: true },
];

// Vulnerability-alert cases: same MATRIX shape plus `vuln: true`, which
// appends a synthetic packageRule mirroring vulnerabilities.ts's
// vulnerabilityToPackageRules() to preset.packageRules for that one case
// only — never to the base preset, so check 1's coverage loop below stays
// scoped to real, authored rules. `datasource` is required (the synthetic
// rule matches on it); `dependencyDashboardApproval: false` on a
// major/toolchain-gate path proves the CVE bypasses that gate, not just
// that a lane survived.
const VULN_MATRIX = [
  { name: "vulnerability alert on an automerging gomod patch (lane survives, still automerges)", ruleIndices: [2, 3, 13], input: { manager: "gomod", datasource: "go", updateType: "patch", depName: "k8s.io/api", packageName: "k8s.io/api" }, expect: "unattended", expectAutomerge: true },
  { name: "vulnerability alert on a dashboard-gated major (gate bypassed, lane still needs-human)", ruleIndices: [11], input: { manager: "gomod", datasource: "go", updateType: "major", depName: "github.com/some/other", packageName: "github.com/some/other" }, expect: "needs-human", expectDashboardApproval: false },
];

let failures = 0;

const touchedIndices = new Set();
for (const c of MATRIX) {
  c.ruleIndices.forEach((i) => touchedIndices.add(i));
  const input = { packageRules: preset.packageRules, labels: preset.labels, ...c.input };
  if (input.packageName === undefined) input.packageName = input.depName;
  for (const i of c.ruleIndices) {
    if (!(await matchesRule(input, preset.packageRules[i]))) {
      console.error(`FAIL [declared-index] ${c.name}: ruleIndices declares ${i}, but packageRules[${i}] does not actually match this case's input — the index is stale (has renovate/shared.json been reordered?) or the case is wrong`);
      failures++;
    }
  }
  const result = await applyPackageRules(input);
  const labelSet = new Set([...(result.labels ?? []), ...(result.addLabels ?? [])]);
  const lanes = LANES.filter((l) => labelSet.has(l));
  if (lanes.length !== 1) {
    console.error(`FAIL [outcome] ${c.name}: expected exactly one lane, got [${lanes.join(", ")}] (labels=${JSON.stringify(result.labels)})`);
    failures++;
    continue;
  }
  if (lanes[0] !== c.expect) {
    console.error(`FAIL [outcome] ${c.name}: expected ${c.expect}, got ${lanes[0]}`);
    failures++;
  }
  // Opt in on key presence, not on the value: a MATRIX case with no matching rule leaves
  // dependencyDashboardApproval genuinely absent (undefined), never a resolved `false` the way
  // the vulnerability-alert defaults produce it below. Boolean(...) on both sides means an
  // absent result correctly satisfies an expected `false`, and a strict `!==` guard here would
  // either skip the assertion entirely (undefined !== undefined is false, so a real regression
  // to `undefined` would pass) or fail a correctly-fixed preset outright.
  if ("expectDashboardApproval" in c && Boolean(result.dependencyDashboardApproval) !== Boolean(c.expectDashboardApproval)) {
    console.error(`FAIL [outcome] ${c.name}: expected dependencyDashboardApproval=${c.expectDashboardApproval}, got ${result.dependencyDashboardApproval}`);
    failures++;
  }
}

for (const c of VULN_MATRIX) {
  c.ruleIndices.forEach((i) => touchedIndices.add(i));
  const vulnRule = {
    matchDatasources: [c.input.datasource],
    matchPackageNames: [c.input.packageName],
    isVulnerabilityAlert: true,
    force: { ...resolvedVulnerabilityAlerts },
  };
  const input = {
    packageRules: [...preset.packageRules, vulnRule],
    labels: preset.labels,
    ...c.input,
  };
  for (const i of c.ruleIndices) {
    if (!(await matchesRule(input, preset.packageRules[i]))) {
      console.error(`FAIL [declared-index] ${c.name}: ruleIndices declares ${i}, but packageRules[${i}] does not actually match this case's input — the index is stale (has renovate/shared.json been reordered?) or the case is wrong`);
      failures++;
    }
  }
  const result = await applyPackageRules(input);
  const labelSet = new Set([...(result.labels ?? []), ...(result.addLabels ?? [])]);
  const lanes = LANES.filter((l) => labelSet.has(l));
  if (lanes.length !== 1) {
    console.error(`FAIL [vuln-outcome] ${c.name}: expected exactly one lane, got [${lanes.join(", ")}] (labels=${JSON.stringify(result.labels)}, addLabels=${JSON.stringify(result.addLabels)})`);
    failures++;
    continue;
  }
  if (lanes[0] !== c.expect) {
    console.error(`FAIL [vuln-outcome] ${c.name}: expected ${c.expect}, got ${lanes[0]}`);
    failures++;
  }
  if (c.expectAutomerge !== undefined && result.automerge !== c.expectAutomerge) {
    console.error(`FAIL [vuln-outcome] ${c.name}: expected automerge=${c.expectAutomerge}, got ${result.automerge}`);
    failures++;
  }
  if (c.expectDashboardApproval !== undefined && result.dependencyDashboardApproval !== c.expectDashboardApproval) {
    console.error(`FAIL [vuln-outcome] ${c.name}: expected dependencyDashboardApproval=${c.expectDashboardApproval}, got ${result.dependencyDashboardApproval}`);
    failures++;
  }
}

const ruleCount = preset.packageRules.length;
for (let i = 0; i < ruleCount; i++) {
  if (!touchedIndices.has(i)) {
    console.error(`FAIL [coverage] packageRules[${i}] (${preset.packageRules[i].groupName ?? preset.packageRules[i].description ?? "unnamed"}) is not exercised by any matrix case`);
    failures++;
  }
}

if ((preset.addLabels ?? []).some((l) => LANES.includes(l))) {
  console.error("FAIL [structural] top-level addLabels sets a lane label");
  failures++;
}
// vulnerabilityAlerts is force-merged (renovate/lib/util/package-rules/
// index.ts) over whichever rule already matched, so `labels` here would
// silently replace the resolved lane rather than add to it — only
// addLabels is safe, and it may not itself carry a lane term.
if (preset.vulnerabilityAlerts) {
  if ("labels" in preset.vulnerabilityAlerts) {
    console.error("FAIL [structural] vulnerabilityAlerts sets `labels`, which force-replaces the resolved lane — use addLabels instead");
    failures++;
  }
  if ((preset.vulnerabilityAlerts.addLabels ?? []).some((l) => LANES.includes(l))) {
    console.error("FAIL [structural] vulnerabilityAlerts.addLabels sets a lane label");
    failures++;
  }
}
preset.packageRules.forEach((rule, i) => {
  if ((rule.addLabels ?? []).some((l) => LANES.includes(l))) {
    console.error(`FAIL [structural] packageRules[${i}] addLabels sets a lane label`);
    failures++;
  }
  if (rule.automerge === false && !(rule.labels ?? []).includes("needs-human")) {
    console.error(`FAIL [structural] packageRules[${i}] has automerge:false but no needs-human label`);
    failures++;
  }
  if (rule.automerge === true && !(rule.labels ?? []).includes("unattended")) {
    console.error(`FAIL [structural] packageRules[${i}] has automerge:true but no unattended label`);
    failures++;
  }
});

if (failures > 0) {
  console.error(`\n${failures} failure(s).`);
  process.exit(1);
}
console.log(`renovate-lane-policy-test: OK (${MATRIX.length} matrix cases, ${VULN_MATRIX.length} vuln cases, ${ruleCount} packageRules all covered)`);
