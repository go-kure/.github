#!/usr/bin/env node
// Asserts every Renovate PR carries exactly one lane label: "unattended"
// (Renovate merges it itself) or "needs-human" (blocked on a review). See
// go-kure/.github#87.
//
// Four checks:
//  1. Outcome — run renovate's own package-rules resolver (applyPackageRules)
//     over a matrix of representative dependency-update paths, one per
//     packageRules entry, over the full preset (so a top-level field the
//     preset sets, not just packageRules/labels, still reaches the
//     resolver the way it would in a real run), and assert the resolved
//     label set contains exactly one lane AND that the resolved automerge
//     value matches what that lane promises — a rule could otherwise keep
//     the label while its automerge setting silently drifts, and the label
//     comparison alone would never catch it. A case may also set
//     `expectDashboardApproval` to assert dependencyDashboardApproval
//     directly (opt-in on key presence, not on the value — see the
//     comparison below for why), or `expectEnabled` to assert the resolved
//     `enabled` value strictly (same opt-in; `undefined` with the key
//     present asserts the value is absent, i.e. no enabled:false rule
//     matched). Also asserts every packageRules index is
//     exercised, so a new rule with no matrix case fails loudly instead of
//     going unexercised — and, separately, that every hand-declared
//     ruleIndices entry actually matches that case's input (via renovate's
//     own per-rule matcher pipeline), so inserting a rule mid-array and
//     silently shifting every later index fails loudly too instead of
//     passing coverage vacuously.
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
//     The same `force` block also overwrites an authored `enabled: false`
//     (mergeChildConfig spreads `force` over the merged result and
//     applyPackageRules clears the skipReason the earlier rule set), which
//     is why a packageRule can never be the guarantee that a path stays out
//     of scope — a vulnerable dep in it would be looked up and PR'd anyway.
//  4. Extraction — resolve the preset through renovate's own preset resolver
//     (resolveConfigPresets, so `extends` is applied the way a real run
//     applies it), take the EFFECTIVE config per manager (getManagerConfig,
//     the merge extract/index.js applies before getMatchingFiles — a
//     manager-level `<manager>.ignorePaths` replaces the top-level list for
//     that manager, and :ignoreModulesAndTests ships exactly such an
//     override for nuget), and run renovate's file filter
//     (filterIgnoredFiles, what getMatchingFiles() calls before any manager
//     extracts) over every case that declares `expectExtracted`: a path
//     the preset means to keep out of scope must be dropped here, before
//     any dep exists for check 3's synthetic rule to re-enable, and a
//     negative control must survive. Two invariants sit in front of the
//     cases: a drift guard — for the plain top-level list and for every
//     manager the installed renovate's own `:ignoreModulesAndTests`
//     overrides, the effective resolved list still carries every inherited
//     entry (ignorePaths is mergeable:false, so the preset restates those
//     lists in full to add an entry, and this is what catches a restated
//     copy drifting from the inherited one) — and a guarantee check: every
//     manager-level override present in the resolved preset, inherited or
//     authored, plus the plain list, drops a testdata file at both depths
//     (a newly inherited override for some other manager would otherwise
//     reopen the gap silently, since the drift guard only compares against
//     what is inherited).
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

// Check 4's three entry points, same sibling-path trick: the preset resolver (applies `extends`,
// internal presets only — no network for config:*/:* names), the per-manager config merge, and
// the extraction-time file filter. Resolve a throwaway clone: resolveConfigPresets compiles
// `extends` in place. It returns { config, visitedPresets } (config/presets/index.ts), and a
// missing `config` here must be loud — `?? []` on the wrong hop would make every extraction
// assertion below pass vacuously.
const presetsModuleSpecifier = moduleSpecifier.replace(
  /util\/package-rules\/index\.js$/,
  "config/presets/index.js",
);
const configModuleSpecifier = moduleSpecifier.replace(
  /util\/package-rules\/index\.js$/,
  "config/index.js",
);
const fileMatchModuleSpecifier = moduleSpecifier.replace(
  /util\/package-rules\/index\.js$/,
  "workers/repository/extract/file-match.js",
);
const { resolveConfigPresets } = await import(presetsModuleSpecifier);
const { getManagerConfig } = await import(configModuleSpecifier);
const { filterIgnoredFiles } = await import(fileMatchModuleSpecifier);
async function resolveOrDie(input, label) {
  const resolved = await resolveConfigPresets(input);
  if (!resolved || typeof resolved.config !== "object" || resolved.config === null) {
    console.error(
      `FATAL: resolveConfigPresets(${label}) returned ${JSON.stringify(Object.keys(resolved ?? {}))} — expected a { config, visitedPresets } wrapper; the installed renovate changed its resolver shape, check 4 cannot run`,
    );
    process.exit(1);
  }
  return resolved.config;
}
const resolvedPreset = await resolveOrDie(structuredClone(preset), "preset");
const inheritedResolved = await resolveOrDie({ extends: [":ignoreModulesAndTests"] }, ":ignoreModulesAndTests");

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
  { name: "mise toolchain minor (e.g. hugo)", ruleIndices: [0, 13], input: { manager: "mise", updateType: "minor", depName: "hugo" }, expect: "unattended" },
  { name: "mise toolchain patch", ruleIndices: [0, 13], input: { manager: "mise", updateType: "patch", depName: "yq" }, expect: "unattended" },
  { name: "mise toolchain digest", ruleIndices: [0, 13], input: { manager: "mise", updateType: "digest", depName: "hugo" }, expect: "unattended" },
  { name: "mise toolchain major (excluded from the automerge group)", ruleIndices: [11], input: { manager: "mise", updateType: "major", depName: "hugo" }, expect: "needs-human" },
  { name: "go itself via mise (dashboard-gated, never automerged)", ruleIndices: [9], input: { manager: "mise", updateType: "minor", depName: "go" }, expect: "needs-human" },
  { name: "go itself via gomod (dashboard-gated, never automerged)", ruleIndices: [9], input: { manager: "gomod", updateType: "patch", depName: "go", packageName: "go" }, expect: "needs-human" },
  { name: "golang dockerfile tag (dashboard-gated, never automerged)", ruleIndices: [10], input: { manager: "dockerfile", updateType: "minor", depName: "golang", packageName: "golang" }, expect: "needs-human" },
  { name: "gomod minor, kubernetes (no automerge rule matches minor)", ruleIndices: [1, 3], input: { manager: "gomod", updateType: "minor", depName: "k8s.io/api", packageName: "k8s.io/api" }, expect: "needs-human" },
  { name: "gomod patch, kubernetes (automerges)", ruleIndices: [2, 3, 14], input: { manager: "gomod", updateType: "patch", depName: "k8s.io/api", packageName: "k8s.io/api" }, expect: "unattended" },
  { name: "gomod digest, sigs.k8s.io (automerges)", ruleIndices: [2, 4, 14], input: { manager: "gomod", updateType: "digest", depName: "sigs.k8s.io/controller-runtime", packageName: "sigs.k8s.io/controller-runtime" }, expect: "unattended" },
  { name: "gomod patch, fluxcd (automerges)", ruleIndices: [2, 5, 14], input: { manager: "gomod", updateType: "patch", depName: "github.com/fluxcd/pkg/oci", packageName: "github.com/fluxcd/pkg/oci" }, expect: "unattended" },
  { name: "gomod patch, cloudnative-pg (automerges)", ruleIndices: [2, 6, 14], input: { manager: "gomod", updateType: "patch", depName: "github.com/cloudnative-pg/machinery", packageName: "github.com/cloudnative-pg/machinery" }, expect: "unattended" },
  // Deliberately does NOT declare 14 here: rule 14's own matchPackageNames excludes
  // github.com/go-kure/**, so it never matches this case — that exclusion is the point being
  // proven (needs-human survives despite sitting right next to the automerge rule). Rule 14's
  // coverage comes from the four automerge cases above that it actually matches.
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
  // Rule 12 (Go testdata fixtures are out of scope) matches on packageFile via matchFileNames —
  // renovate's FileNamesMatcher reads `packageFile` (then `lockFiles`, absent here). `**/testdata/**`
  // alone matches both shapes on Renovate 44 (a leading `**` matches zero segments; verified on
  // 44.14.10, 44.42.0 and 44.65.3), and the rule's second spelling `testdata/**` is deliberately
  // redundant. The root-level case below is what pins the root-level behaviour if that anchoring
  // ever changes; it does not settle which spelling matched. The lane stays the top-level default
  // (needs-human) because the rule sets no labels and no other rule matches a helm-values dep.
  // In a real run neither file is ever extracted: the top-level ignorePaths drops them first
  // (`expectExtracted: false`, check 4), and the rule is the fallback for a consumer whose own
  // ignorePaths replaced the preset's list — so these two cases pin the fallback, and check 4
  // pins the guarantee. Origin: a placeholder image in a values.yaml fixture drew a permanent
  // "Package lookup failures" block on a consumer's Dependency Dashboard (go-kure/launcher#301).
  { name: "helm-values placeholder image in a nested Go testdata fixture (disabled, never looked up)", ruleIndices: [12], input: { manager: "helm-values", updateType: "minor", depName: "myregistry/app", packageName: "myregistry/app", packageFile: "pkg/cmd/tool/testdata/params/values.yaml" }, expect: "needs-human", expectEnabled: false, expectExtracted: false },
  { name: "helm-values placeholder image in a root-level testdata fixture (disabled, never looked up)", ruleIndices: [12], input: { manager: "helm-values", updateType: "minor", depName: "myregistry/app", packageName: "myregistry/app", packageFile: "testdata/values.yaml" }, expect: "needs-human", expectEnabled: false, expectExtracted: false },
  // Negative control for rule 12: the same dep outside any testdata tree must NOT be disabled.
  // `expectEnabled: undefined` with the key present opts into the assertion (key presence, same
  // convention as expectDashboardApproval) and pins the resolved value to "absent" — the preset
  // sets no top-level enabled, so anything else here means the rule over-matched. Also the
  // negative control for check 4: the file must survive extraction.
  { name: "helm-values image outside testdata (rule 12 must not match)", ruleIndices: [], input: { manager: "helm-values", updateType: "minor", depName: "myregistry/app", packageName: "myregistry/app", packageFile: "charts/app/values.yaml" }, expect: "needs-human", expectEnabled: undefined, expectExtracted: true },
  // A directory whose name merely contains "testdata" is not a testdata tree: both the rule's
  // globs and the ignorePaths entry are segment-anchored, and filterIgnoredFiles' substring
  // fallback (`file.includes(ignorePath)`) never matches a literal glob against a real path.
  { name: "gomod dep in a directory merely named like testdata (neither disabled nor dropped)", ruleIndices: [2, 14], input: { manager: "gomod", updateType: "patch", depName: "github.com/some/other", packageName: "github.com/some/other", packageFile: "pkg/testdata_helper/go.mod" }, expect: "unattended", expectEnabled: undefined, expectExtracted: true },
  // nuget is the one manager :ignoreModulesAndTests overrides (nuget.ignorePaths, which keeps
  // test/ and tests/ in scope), and getManagerConfig merges that override OVER the top-level
  // list, so the top-level **/testdata/** never reaches nuget on its own — the preset restates
  // nuget's list with the entry added. First case pins that; second pins that the restated copy
  // kept renovate's own nuget exception (test/ still extracted) instead of silently widening it.
  { name: "nuget project file in a root-level testdata fixture (dropped via the restated nuget override)", ruleIndices: [12], input: { manager: "nuget", updateType: "minor", depName: "Newtonsoft.Json", packageName: "Newtonsoft.Json", packageFile: "testdata/Fixture.csproj" }, expect: "needs-human", expectEnabled: false, expectExtracted: false },
  { name: "nuget project file under test/ (renovate's own nuget exception, must survive)", ruleIndices: [], input: { manager: "nuget", updateType: "minor", depName: "Newtonsoft.Json", packageName: "Newtonsoft.Json", packageFile: "test/Foo.csproj" }, expect: "needs-human", expectEnabled: undefined, expectExtracted: true },
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
  { name: "vulnerability alert on an automerging gomod patch (lane survives, still automerges)", ruleIndices: [2, 3, 14], input: { manager: "gomod", datasource: "go", updateType: "patch", depName: "k8s.io/api", packageName: "k8s.io/api" }, expect: "unattended", expectAutomerge: true },
  { name: "vulnerability alert on a dashboard-gated major (gate bypassed, lane still needs-human)", ruleIndices: [11], input: { manager: "gomod", datasource: "go", updateType: "major", depName: "github.com/some/other", packageName: "github.com/some/other" }, expect: "needs-human", expectDashboardApproval: false },
  // Rule 12's enabled:false does NOT survive the synthetic rule: force.enabled:true clears the
  // skipReason rule 12 set and overwrites enabled (verified on 44.14.10, 44.42.0 and 44.65.3,
  // both the OSV and the GitHub-alert rule shapes). `expectEnabled: true` pins exactly that, so
  // the reason ignorePaths carries the guarantee stays a tested fact rather than a comment — if
  // this ever fails, renovate changed force precedence and the rule-12 description is stale.
  // `expectExtracted: false` is the guarantee itself: the file never reaches package rules.
  { name: "vulnerability alert on a gomod dep inside a testdata tree (force re-enables rule 12; extraction is what keeps it out)", ruleIndices: [2, 12, 14], input: { manager: "gomod", datasource: "go", updateType: "patch", depName: "github.com/some/vulnerable", packageName: "github.com/some/vulnerable", packageFile: "pkg/foo/testdata/mod/go.mod" }, expect: "unattended", expectEnabled: true, expectExtracted: false },
];

let failures = 0;

const touchedIndices = new Set();
for (const c of MATRIX) {
  c.ruleIndices.forEach((i) => touchedIndices.add(i));
  // Spread the whole preset, not just packageRules/labels: a top-level field this preset adds
  // later (e.g. dependencyDashboardApproval) must reach applyPackageRules the same way it would
  // in a real run, or a regression there would resolve to `undefined` here and pass every
  // Boolean(...) comparison below for the wrong reason. c.input still overlays last so each
  // case's own dependency fields win.
  const input = { ...preset, ...c.input };
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
  // Strict, not Boolean(): an enabled:false rule is the one whose whole effect is the literal
  // false, and a case that expects the rule NOT to match pins the value to undefined — the
  // preset sets no top-level enabled, so a Boolean() comparison could not tell "absent" from a
  // regression that set it to false everywhere.
  if ("expectEnabled" in c && result.enabled !== c.expectEnabled) {
    console.error(`FAIL [outcome] ${c.name}: expected enabled=${c.expectEnabled}, got ${result.enabled}`);
    failures++;
  }
  // The lane label alone doesn't prove the behavior it names: a rule could keep the
  // "unattended" label while its automerge:true is accidentally dropped (or vice versa), and
  // the outcome check above would still pass since it only compares labels. Assert the
  // resolved automerge value matches what the lane promises, the same way VULN_MATRIX already
  // does via expectAutomerge below.
  if (lanes[0] === "unattended" && result.automerge !== true) {
    console.error(`FAIL [outcome] ${c.name}: lane is unattended but resolved automerge=${result.automerge}, expected true`);
    failures++;
  }
  if (lanes[0] === "needs-human" && Boolean(result.automerge)) {
    console.error(`FAIL [outcome] ${c.name}: lane is needs-human but resolved automerge=${result.automerge}, expected falsy`);
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
    ...preset,
    packageRules: [...preset.packageRules, vulnRule],
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
  // Key-presence opt-in and strict comparison, same as MATRIX's expectEnabled above.
  if ("expectEnabled" in c && result.enabled !== c.expectEnabled) {
    console.error(`FAIL [vuln-outcome] ${c.name}: expected enabled=${c.expectEnabled}, got ${result.enabled}`);
    failures++;
  }
}

// Check 4 — extraction. Everything here runs on the EFFECTIVE per-manager config
// (getManagerConfig, the merge extract/index.js applies before getMatchingFiles), never on the
// top-level object: a `<manager>.ignorePaths` block replaces the top-level list for that manager
// (ignorePaths is mergeable:false), so a top-level entry is in force only where no override
// shadows it. :ignoreModulesAndTests ships such an override for nuget.
const effectiveIgnorePaths = (config, manager) => getManagerConfig(config, manager).ignorePaths ?? [];
// Managers whose config object carries its own ignorePaths — the overrides, discovered rather than
// listed, so an override renovate adds upstream (or one authored here) is covered without editing
// this file. packageRules is an array and vulnerabilityAlerts has no ignorePaths, so neither
// qualifies; nuget does.
const overrideManagersOf = (config) =>
  Object.keys(config).filter((k) => {
    const v = config[k];
    return v !== null && typeof v === "object" && !Array.isArray(v) && Array.isArray(v.ignorePaths);
  });
// A manager with no override of its own: "the top-level list as a real run sees it".
const PLAIN_MANAGER = "gomod";
// Drift guard: for the plain list and for every manager the installed renovate's own
// :ignoreModulesAndTests overrides, the effective resolved list must still carry every inherited
// entry — the preset restates those lists in full to add one entry, and this is what catches a
// restated copy drifting from the inherited one (or a restated override outliving the upstream
// one it shadows: the inherited effective list then falls back to the top-level eight, and the
// six-entry restated copy fails on test/ and tests/).
for (const m of [PLAIN_MANAGER, ...overrideManagersOf(inheritedResolved)]) {
  const inherited = effectiveIgnorePaths(inheritedResolved, m);
  const resolved = effectiveIgnorePaths(resolvedPreset, m);
  for (const p of inherited) {
    if (!resolved.includes(p)) {
      console.error(`FAIL [extraction] effective ignorePaths for manager ${m} lacks inherited entry ${JSON.stringify(p)} — the preset's restated list has drifted from renovate's :ignoreModulesAndTests (installed effective list for ${m}: ${JSON.stringify(inherited)}, resolved: ${JSON.stringify(resolved)})`);
      failures++;
    }
  }
}
// Guarantee: every manager-level override present in the RESOLVED preset (inherited or authored),
// plus the plain list, must drop a testdata file at both depths. The drift guard alone would let
// a newly inherited override for some other manager reopen the gap silently, since it only
// compares against what is inherited.
const TESTDATA_PROBES = ["testdata/probe", "a/b/testdata/probe"];
for (const m of [PLAIN_MANAGER, ...overrideManagersOf(resolvedPreset)]) {
  const kept = filterIgnoredFiles(TESTDATA_PROBES, effectiveIgnorePaths(resolvedPreset, m));
  if (kept.length !== 0) {
    console.error(`FAIL [extraction] manager ${m} still extracts ${JSON.stringify(kept)} — its effective ignorePaths ${JSON.stringify(effectiveIgnorePaths(resolvedPreset, m))} lacks a testdata entry (a manager-level override shadows the top-level list; restate it with **/testdata/** added)`);
    failures++;
  }
}
// Then the cases, through the same filter a real run applies before any manager extracts, on
// that case's manager: expectExtracted:false names a file the preset must drop, so no dep ever
// exists for a package rule — authored or synthetic — to act on; expectExtracted:true is the
// control.
let extractionCases = 0;
for (const c of [...MATRIX, ...VULN_MATRIX]) {
  if (!("expectExtracted" in c)) continue;
  extractionCases++;
  const { packageFile, manager } = c.input;
  if (typeof packageFile !== "string" || typeof manager !== "string") {
    console.error(`FAIL [extraction] ${c.name}: declares expectExtracted but input lacks packageFile or manager`);
    failures++;
    continue;
  }
  const effective = effectiveIgnorePaths(resolvedPreset, manager);
  const extracted = filterIgnoredFiles([packageFile], effective).length === 1;
  if (extracted !== c.expectExtracted) {
    console.error(`FAIL [extraction] ${c.name}: expected ${packageFile} extracted=${c.expectExtracted} for manager ${manager}, got ${extracted} (effective ignorePaths: ${JSON.stringify(effective)})`);
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
console.log(`renovate-lane-policy-test: OK (${MATRIX.length} matrix cases, ${VULN_MATRIX.length} vuln cases, ${extractionCases} extraction cases, ${ruleCount} packageRules all covered)`);
