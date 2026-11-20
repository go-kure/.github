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
//     comparison below for why), `expectEnabled` to assert the resolved
//     `enabled` value strictly (same opt-in; `undefined` with the key
//     present asserts the value is absent, i.e. no enabled:false rule
//     matched), or `expectGroupName` to assert the resolved `groupName`
//     (same opt-in) — the lane label proves automerge eligibility, not
//     which branch a dep lands on, and Renovate ANDs automerge across every
//     member of one grouped branch, so two deps sharing a groupName share a
//     branch regardless of what their own labels say. `expectSeparateMinorPatch`
//     asserts separateMinorPatch the same way as `expectDashboardApproval`
//     (opt-in on key presence, `Boolean()` comparison). Also asserts every packageRules index is
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
//     manager either the installed renovate's own `:ignoreModulesAndTests`
//     or the preset overrides, the effective resolved list still carries
//     every effective inherited entry (ignorePaths is mergeable:false, so
//     the preset restates those lists in full to add an entry, and this is
//     what catches a restated copy drifting from the inherited one, or
//     outliving the upstream override it restates) — and a guarantee check: every
//     manager-level override present in the resolved preset, inherited or
//     authored, plus the plain list, drops a testdata file at both depths
//     (a newly inherited override for some other manager would otherwise
//     reopen the gap silently, since the drift guard only compares against
//     what is inherited).
//  6. Update-type oracle — Renovate's own classifyRelease over version pairs: a
//     pre-release bump (rc.2 to rc.3) and the step to the final release are
//     "patch", and a v0.0.0- pseudo-version replacing another is reclassified
//     "digest" by lookup/index.js (pinned by source text). The lanes route on
//     updateType, so a Renovate upgrade that reclassifies fails here.
//  7. Branch partition — for every group where a patch automerges and a minor
//     does not, Renovate's own generateBranchName must put the two on different
//     branches (a grouped branch automerges only when every member does, and is
//     held when any member needs dashboard approval), with a control that strips separateMinorPatch and must see one.
//  8. Candidate selection — Renovate's own getBucket must put a patch and a
//     minor release of one dependency in different buckets for every manager
//     the lanes route (separateMinorPatch is read at lookup, before any
//     update-type rule; with it off only the minor is offered and the patch
//     lane never sees a patch), with a control that strips the flag.
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
// missing `config` here must be loud: `?? []` on the wrong hop would leave the drift guard
// with nothing inherited to compare against (a vacuous pass) and fail every exclusion case with
// a misleading empty-list diagnostic (filterIgnoredFiles keeps everything when the list is
// empty), so the resolver's shape is asserted here instead of papered over.
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
// Checks 6 and 7: Renovate's own update-type classifier, branch-name generator and versioning
// registry, found by the same sibling-path trick, so the lane promises that depend on how a
// version step is classified and on which branch it lands are tested against the installed
// Renovate and not against a description of it.
const distRoot = (rel) => moduleSpecifier.replace(/util\/package-rules\/index\.js$/, rel);
const updateTypeModuleSpecifier = distRoot("workers/repository/process/lookup/update-type.js");
const lookupModuleSpecifier = distRoot("workers/repository/process/lookup/index.js");
const branchNameModuleSpecifier = distRoot("workers/repository/updates/branch-name.js");
const versioningModuleSpecifier = distRoot("modules/versioning/index.js");
// The classifier is named classifyRelease(api, from, to) from 44.101 and getUpdateType(config,
// api, from, to) before it (44.46 is the CI pin); both compare only major and minor.
const updateTypeModule = await import(updateTypeModuleSpecifier);
const classifyRelease = updateTypeModule.classifyRelease
  ?? ((api, from, to) => updateTypeModule.getUpdateType({}, api, from, to));
if (typeof classifyRelease !== "function" || (!updateTypeModule.classifyRelease && !updateTypeModule.getUpdateType)) {
  console.error(`FATAL: ${updateTypeModuleSpecifier} exports neither classifyRelease nor getUpdateType; check 6 cannot run`);
  process.exit(1);
}
const { generateBranchName } = await import(branchNameModuleSpecifier);
const { get: getVersioning } = await import(versioningModuleSpecifier);
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
  { name: "mise toolchain minor (e.g. hugo)", ruleIndices: [0, 18], input: { manager: "mise", updateType: "minor", depName: "hugo" }, expect: "unattended" },
  { name: "mise toolchain patch", ruleIndices: [0, 17], input: { manager: "mise", updateType: "patch", depName: "yq" }, expect: "unattended" },
  { name: "mise toolchain digest", ruleIndices: [0, 17], input: { manager: "mise", updateType: "digest", depName: "hugo" }, expect: "unattended" },
  { name: "mise toolchain major (excluded from the automerge group)", ruleIndices: [14], input: { manager: "mise", updateType: "major", depName: "hugo" }, expect: "needs-human" },
  // expectMinimumReleaseAge: node from the mise datasource is published before its Docker Hub
  // image, so rule 19 holds a node bump for three days. A mise tool other than node, and node
  // under another manager, must not pick it up (strict comparison, key-presence opt-in).
  { name: "node via mise patch (held three days, still automerges)", ruleIndices: [0, 17, 19], input: { manager: "mise", updateType: "patch", depName: "node" }, expect: "unattended", expectMinimumReleaseAge: "3 days" },
  { name: "node via mise minor (held three days)", ruleIndices: [0, 18, 19], input: { manager: "mise", updateType: "minor", depName: "node" }, expect: "unattended", expectMinimumReleaseAge: "3 days" },
  { name: "other mise tool (no release-age hold)", ruleIndices: [0, 17], input: { manager: "mise", updateType: "patch", depName: "yq" }, expect: "unattended", expectMinimumReleaseAge: undefined },
  { name: "node dockerfile tag (no release-age hold, reads the image tags themselves; a patch automerges, everything-else lane)", ruleIndices: [21], input: { manager: "dockerfile", updateType: "patch", depName: "node" }, expect: "unattended", expectMinimumReleaseAge: undefined },
  // expectSeparateMinorPatch: the two Go rules split a previous-minor patch from the next-minor
  // move, so a repo one minor behind still sees its patches (renovate/shared.json, rule 12).
  { name: "go itself via mise (dashboard-gated, never automerged)", ruleIndices: [12], input: { manager: "mise", updateType: "minor", depName: "go" }, expect: "needs-human", expectSeparateMinorPatch: true },
  { name: "go itself via gomod (dashboard-gated, never automerged)", ruleIndices: [12], input: { manager: "gomod", updateType: "patch", depName: "go", packageName: "go" }, expect: "needs-human", expectSeparateMinorPatch: true },
  { name: "golang dockerfile tag (dashboard-gated, never automerged)", ruleIndices: [13], input: { manager: "dockerfile", updateType: "minor", depName: "golang", packageName: "golang" }, expect: "needs-human", expectSeparateMinorPatch: true },
  // Every gomod minor is dashboard-gated by rule 1 (nobody automerges a minor, so Renovate opens
  // one only when its box is ticked); the group rules below only rename the group and inherit the
  // gate, which is why each group gets its own minor case. The patch cases pin the other side:
  // a patch is not gated.
  { name: "gomod minor, ungrouped (dashboard-gated, never automerged)", ruleIndices: [1], input: { manager: "gomod", updateType: "minor", depName: "github.com/some/other", packageName: "github.com/some/other" }, expect: "needs-human", expectDashboardApproval: true, expectGroupName: "go-minor" },
  { name: "gomod minor, kubernetes (dashboard-gated, never automerged)", ruleIndices: [1, 3], input: { manager: "gomod", updateType: "minor", depName: "k8s.io/api", packageName: "k8s.io/api" }, expect: "needs-human", expectDashboardApproval: true, expectGroupName: "kubernetes" },
  { name: "gomod minor, sigs.k8s.io (dashboard-gated, never automerged)", ruleIndices: [1, 4], input: { manager: "gomod", updateType: "minor", depName: "sigs.k8s.io/controller-runtime", packageName: "sigs.k8s.io/controller-runtime" }, expect: "needs-human", expectDashboardApproval: true, expectGroupName: "sigs.k8s.io" },
  { name: "gomod minor, fluxcd (dashboard-gated, never automerged)", ruleIndices: [1, 5], input: { manager: "gomod", updateType: "minor", depName: "github.com/fluxcd/pkg/oci", packageName: "github.com/fluxcd/pkg/oci" }, expect: "needs-human", expectDashboardApproval: true, expectGroupName: "fluxcd" },
  { name: "gomod minor, cloudnative-pg (dashboard-gated, never automerged)", ruleIndices: [1, 6], input: { manager: "gomod", updateType: "minor", depName: "github.com/cloudnative-pg/machinery", packageName: "github.com/cloudnative-pg/machinery" }, expect: "needs-human", expectDashboardApproval: true, expectGroupName: "cloudnative-pg" },
  { name: "gomod minor, first-party go-kure (dashboard-gated, never automerged)", ruleIndices: [1, 7], input: { manager: "gomod", updateType: "minor", depName: "github.com/go-kure/kure", packageName: "github.com/go-kure/kure" }, expect: "needs-human", expectDashboardApproval: true, expectGroupName: "internal" },
  { name: "gomod patch, kubernetes (automerges, not gated)", ruleIndices: [2, 3, 20], input: { manager: "gomod", updateType: "patch", depName: "k8s.io/api", packageName: "k8s.io/api" }, expect: "unattended", expectDashboardApproval: false },
  { name: "gomod digest, sigs.k8s.io (automerges)", ruleIndices: [2, 4, 20], input: { manager: "gomod", updateType: "digest", depName: "sigs.k8s.io/controller-runtime", packageName: "sigs.k8s.io/controller-runtime" }, expect: "unattended" },
  { name: "gomod patch, fluxcd (automerges)", ruleIndices: [2, 5, 20], input: { manager: "gomod", updateType: "patch", depName: "github.com/fluxcd/pkg/oci", packageName: "github.com/fluxcd/pkg/oci" }, expect: "unattended" },
  { name: "gomod patch, cloudnative-pg (automerges)", ruleIndices: [2, 6, 20], input: { manager: "gomod", updateType: "patch", depName: "github.com/cloudnative-pg/machinery", packageName: "github.com/cloudnative-pg/machinery" }, expect: "unattended" },
  // Deliberately does NOT declare 20 here: rule 20's own matchPackageNames excludes
  // github.com/go-kure/**, so it never matches this case — that exclusion is the point being
  // proven (needs-human survives despite sitting right next to the automerge rule). Rule 20's
  // coverage comes from the four automerge cases above that it actually matches.
  { name: "gomod patch, first-party go-kure (opens a pull request without a tick, never automerged)", ruleIndices: [2, 7, 8], input: { manager: "gomod", updateType: "patch", depName: "github.com/go-kure/kure", packageName: "github.com/go-kure/kure" }, expect: "needs-human", expectDashboardApproval: false, expectGroupName: "internal", expectSeparateMinorPatch: true },
  { name: "gomod digest, first-party go-kure (dashboard-gated, never automerged)", ruleIndices: [2, 7], input: { manager: "gomod", updateType: "digest", depName: "github.com/go-kure/kure", packageName: "github.com/go-kure/kure" }, expect: "needs-human", expectDashboardApproval: true, expectGroupName: "internal" },
  { name: "gomod major, first-party go-kure (dashboard-gated, never automerged)", ruleIndices: [7, 14], input: { manager: "gomod", updateType: "major", depName: "github.com/go-kure/kure", packageName: "github.com/go-kure/kure" }, expect: "needs-human", expectDashboardApproval: true, expectGroupName: "internal" },
  { name: "gomod major, any dep (dashboard-gated, never automerged)", ruleIndices: [14], input: { manager: "gomod", updateType: "major", depName: "github.com/some/other", packageName: "github.com/some/other" }, expect: "needs-human", expectDashboardApproval: true },
  // The trusted GitHub Actions lane (go-kure/kure#813's dependency; go-kure/.github#217): tier 1
  // (go-kure/.github itself) and tier 2 (the five listed GitHub-maintained actions) automerge on
  // digest/minor/patch via rule 16's own groupName, separate from rule 11's plain github-actions
  // group that every OTHER action still resolves into. expectGroupName pins the split itself, not
  // just the label: a regression that dropped rule 16's matchDepNames but left automerge:true
  // would still flip these two lanes correctly while silently merging the branch back with tier 3.
  { name: "github-actions tier 1 (go-kure/.github, automerges via its own group)", ruleIndices: [11, 16], input: { manager: "github-actions", updateType: "digest", depName: "go-kure/.github", packageName: "go-kure/.github" }, expect: "unattended", expectGroupName: "github-actions-trusted" },
  { name: "github-actions tier 2 (actions/checkout, automerges via its own group)", ruleIndices: [11, 16], input: { manager: "github-actions", updateType: "minor", depName: "actions/checkout", packageName: "actions/checkout" }, expect: "unattended", expectGroupName: "github-actions-trusted" },
  // The one third-party action the owner accepted into the trusted lane by decision, not by the
  // low-blast-radius test the actions/* names meet: anthropics/claude-code-action. It joins rule 16
  // by exact depName, so digest, minor and patch automerge in the trusted group, a major does not
  // (the second-to-last case below), and a sibling action of the same owner does not ride along
  // (the last case).
  { name: "github-actions owner-accepted action (anthropics/claude-code-action digest, automerges via the trusted group)", ruleIndices: [11, 16], input: { manager: "github-actions", updateType: "digest", depName: "anthropics/claude-code-action", packageName: "anthropics/claude-code-action" }, expect: "unattended", expectGroupName: "github-actions-trusted" },
  { name: "github-actions owner-accepted action (anthropics/claude-code-action minor, automerges via the trusted group)", ruleIndices: [11, 16], input: { manager: "github-actions", updateType: "minor", depName: "anthropics/claude-code-action", packageName: "anthropics/claude-code-action" }, expect: "unattended", expectGroupName: "github-actions-trusted" },
  { name: "github-actions owner-accepted action (anthropics/claude-code-action patch, automerges via the trusted group)", ruleIndices: [11, 16], input: { manager: "github-actions", updateType: "patch", depName: "anthropics/claude-code-action", packageName: "anthropics/claude-code-action" }, expect: "unattended", expectGroupName: "github-actions-trusted" },
  { name: "github-actions owner-accepted action, major (anthropics/claude-code-action, dashboard-gated, excluded from the trusted lane by update type)", ruleIndices: [11, 14], input: { manager: "github-actions", updateType: "major", depName: "anthropics/claude-code-action", packageName: "anthropics/claude-code-action" }, expect: "needs-human", expectDashboardApproval: true, expectGroupName: "github-actions" },
  { name: "github-actions sibling of the owner-accepted action (anthropics/claude-code-base-action, never automerged, stays in the plain group)", ruleIndices: [11], input: { manager: "github-actions", updateType: "minor", depName: "anthropics/claude-code-base-action", packageName: "anthropics/claude-code-base-action" }, expect: "needs-human", expectGroupName: "github-actions" },
  // The GoReleaser pin is no action: release-publish.yml passes it to goreleaser-action as
  // `version:`, and the github-actions manager reads that input as goreleaser/goreleaser. It joins
  // rule 16 by exact depName on the owner's decision of 2026-11-20, so digest, minor and patch
  // automerge in the trusted group and a major waits on the dashboard in the plain group.
  { name: "github-actions owner-accepted pin (goreleaser/goreleaser digest, automerges via the trusted group)", ruleIndices: [11, 16], input: { manager: "github-actions", updateType: "digest", depName: "goreleaser/goreleaser", packageName: "goreleaser/goreleaser" }, expect: "unattended", expectGroupName: "github-actions-trusted" },
  { name: "github-actions owner-accepted pin (goreleaser/goreleaser minor, automerges via the trusted group)", ruleIndices: [11, 16], input: { manager: "github-actions", updateType: "minor", depName: "goreleaser/goreleaser", packageName: "goreleaser/goreleaser" }, expect: "unattended", expectGroupName: "github-actions-trusted" },
  { name: "github-actions owner-accepted pin (goreleaser/goreleaser patch, automerges via the trusted group)", ruleIndices: [11, 16], input: { manager: "github-actions", updateType: "patch", depName: "goreleaser/goreleaser", packageName: "goreleaser/goreleaser" }, expect: "unattended", expectGroupName: "github-actions-trusted" },
  { name: "github-actions owner-accepted pin, major (goreleaser/goreleaser, dashboard-gated, excluded from the trusted lane by update type)", ruleIndices: [11, 14], input: { manager: "github-actions", updateType: "major", depName: "goreleaser/goreleaser", packageName: "goreleaser/goreleaser" }, expect: "needs-human", expectDashboardApproval: true, expectGroupName: "github-actions" },
  { name: "github-actions tier 3 (third-party action, never automerged, stays in the plain group)", ruleIndices: [11], input: { manager: "github-actions", updateType: "minor", depName: "codecov/codecov-action", packageName: "codecov/codecov-action" }, expect: "needs-human", expectGroupName: "github-actions" },
  // An unlisted Action stays out of the everything-else lane: a patch needs a person, like its
  // minor, because only the trusted lane automerges an Action (the tail rule excludes the manager).
  { name: "github-actions unlisted/unknown action, patch (never automerged: only the trusted lane automerges an Action)", ruleIndices: [11], input: { manager: "github-actions", updateType: "patch", depName: "some-org/some-action", packageName: "some-org/some-action" }, expect: "needs-human", expectGroupName: "github-actions" },
  { name: "github-actions unlisted/unknown action, minor (opens a pull request for a hand merge, plain group)", ruleIndices: [11], input: { manager: "github-actions", updateType: "minor", depName: "some-org/some-action", packageName: "some-org/some-action" }, expect: "needs-human", expectDashboardApproval: false, expectGroupName: "github-actions" },
  // Core library Go modules: patch automerges, minor and major wait on the dashboard, and each
  // group splits patch from minor (separateMinorPatch) so they never share a branch.
  { name: "gomod patch, external-secrets (core library, automerges)", ruleIndices: [2, 20], input: { manager: "gomod", updateType: "patch", depName: "github.com/external-secrets/external-secrets", packageName: "github.com/external-secrets/external-secrets" }, expect: "unattended", expectDashboardApproval: false, expectSeparateMinorPatch: true },
  { name: "gomod minor, helm (core library, dashboard-gated)", ruleIndices: [1], input: { manager: "gomod", updateType: "minor", depName: "helm.sh/helm/v4", packageName: "helm.sh/helm/v4" }, expect: "needs-human", expectDashboardApproval: true, expectSeparateMinorPatch: true },
  { name: "gomod patch, kubernetes keeps patch and minor on separate branches", ruleIndices: [2, 3, 20], input: { manager: "gomod", updateType: "patch", depName: "k8s.io/client-go", packageName: "k8s.io/client-go" }, expect: "unattended", expectDashboardApproval: false, expectSeparateMinorPatch: true, expectGroupName: "kubernetes" },
  // Core library pins a manager other than gomod reads: the flux2 tool (mise), the flux-operator
  // chart pin and release pins (custom regex, docker datasource).
  { name: "flux2 via mise, patch (core library: automerges)", ruleIndices: [9, 10, 17], input: { manager: "mise", updateType: "patch", depName: "flux2" }, expect: "unattended", expectDashboardApproval: false, expectSeparateMinorPatch: true },
  { name: "flux2 via mise, minor (core library: dashboard-gated, out of the toolchain group and the mise minor automerge)", ruleIndices: [9], input: { manager: "mise", updateType: "minor", depName: "flux2" }, expect: "needs-human", expectDashboardApproval: true, expectSeparateMinorPatch: true },
  { name: "flux2 via mise, major (dashboard-gated)", ruleIndices: [9, 14], input: { manager: "mise", updateType: "major", depName: "flux2" }, expect: "needs-human", expectDashboardApproval: true },
  { name: "flux-operator chart pin via regex, patch (core library: automerges)", ruleIndices: [9, 10, 21], input: { manager: "regex", updateType: "patch", depName: "ghcr.io/controlplaneio-fluxcd/charts/flux-operator", packageName: "ghcr.io/controlplaneio-fluxcd/charts/flux-operator" }, expect: "unattended", expectDashboardApproval: false },
  { name: "flux-operator chart pin via regex, minor (core library: dashboard-gated)", ruleIndices: [9], input: { manager: "regex", updateType: "minor", depName: "ghcr.io/controlplaneio-fluxcd/charts/flux-operator", packageName: "ghcr.io/controlplaneio-fluxcd/charts/flux-operator" }, expect: "needs-human", expectDashboardApproval: true },
  { name: "flux-operator chart pin via regex, digest (not gated, opens a pull request, as before)", ruleIndices: [9, 10], input: { manager: "regex", updateType: "digest", depName: "ghcr.io/controlplaneio-fluxcd/charts/flux-operator", packageName: "ghcr.io/controlplaneio-fluxcd/charts/flux-operator" }, expect: "needs-human", expectDashboardApproval: false },
  { name: "external-secrets release pin via regex, minor (core library: dashboard-gated)", ruleIndices: [9], input: { manager: "regex", updateType: "minor", depName: "external-secrets/external-secrets", packageName: "external-secrets/external-secrets" }, expect: "needs-human", expectDashboardApproval: true },
  // Everything else: patch automerges, minor opens a pull request for a hand merge, major waits
  // on the dashboard (the major gate). go and golang stay gated by their own rules.
  { name: "npm patch (everything else: automerges)", ruleIndices: [21], input: { manager: "npm", updateType: "patch", depName: "some-pkg", packageName: "some-pkg" }, expect: "unattended", expectDashboardApproval: false },
  { name: "npm minor (everything else: opens a pull request, not gated, not automerged)", ruleIndices: [], input: { manager: "npm", updateType: "minor", depName: "some-pkg", packageName: "some-pkg" }, expect: "needs-human", expectDashboardApproval: false },
  { name: "docker-compose image patch (everything else: automerges)", ruleIndices: [21], input: { manager: "docker-compose", updateType: "patch", depName: "postgres", packageName: "postgres" }, expect: "unattended" },
  { name: "gitlabci image patch (everything else: automerges)", ruleIndices: [21], input: { manager: "gitlabci", updateType: "patch", depName: "alpine", packageName: "alpine" }, expect: "unattended" },
  { name: "custom regex pin patch (everything else: automerges)", ruleIndices: [21], input: { manager: "regex", updateType: "patch", depName: "git-cliff", packageName: "orhun/git-cliff" }, expect: "unattended" },
  { name: "golang dockerfile patch (go lane stays gated: the everything-else rule excludes it)", ruleIndices: [13], input: { manager: "dockerfile", updateType: "patch", depName: "golang", packageName: "golang" }, expect: "needs-human", expectDashboardApproval: true },
  // Major excluded by rule 16's own matchUpdateTypes, not merely by rule 14's dashboard gate
  // (which only blocks branch/PR creation, not merging one already open) — proven by using a
  // tier-2 depName that WOULD automerge on a non-major update (the case just above).
  { name: "github-actions tier-2 dep, major (dashboard-gated, excluded from the trusted lane by update type)", ruleIndices: [11, 14], input: { manager: "github-actions", updateType: "major", depName: "actions/checkout", packageName: "actions/checkout" }, expect: "needs-human", expectDashboardApproval: true, expectGroupName: "github-actions" },
  { name: "npm major (dashboard-gated, never automerged)", ruleIndices: [14], input: { manager: "npm", updateType: "major", depName: "some-pkg", packageName: "some-pkg" }, expect: "needs-human" },
  { name: "dockerfile dep matching no groupRule at all (top-level default)", ruleIndices: [], input: { manager: "dockerfile", updateType: "minor", depName: "alpine", packageName: "alpine" }, expect: "needs-human", expectDashboardApproval: false, expectSeparateMinorPatch: true },
  // customManagers (regex/jsonata) entries report here as "custom.<customType>" (renovate's
  // ManagersMatcher qualifies the config.manager value at match time), never the bare type name
  // the entry's own config carries. These three cases prove the fix (go-kure/.github#87's own
  // history closed exactly this hole): a custom-managed major hits the general gate (rule 14); a
  // custom-managed non-major hits neither gate; and a custom-managed dependency literally named
  // "go" is caught by the dedicated Go rule (rule 12), not the general gate, since that rule alone
  // still carries the allowedVersions ceiling and gates go's non-major bumps too.
  { name: "custom-manager major (dashboard-gated)", ruleIndices: [14], input: { manager: "regex", updateType: "major", depName: "golangci-lint", packageName: "golangci/golangci-lint" }, expect: "needs-human", expectDashboardApproval: true },
  { name: "custom-manager minor (no gate, no automerge)", ruleIndices: [], input: { manager: "regex", updateType: "minor", depName: "git-cliff", packageName: "orhun/git-cliff" }, expect: "needs-human", expectDashboardApproval: false },
  // updateType is "minor", not "major": on a major this case would pass even with rule 12's
  // custom.* left unfixed, since rule 14 (the general gate, matchUpdateTypes:["major"]) already
  // covers a custom-managed go major once its own !go exclusion is dropped. A minor isolates
  // rule 12 — rule 14 never matches a non-major update at all — so this case actually requires
  // rule 12's own matchManagers widening, not just rule 14's.
  { name: "custom-manager depName go, minor (dedicated Go rule only — general gate never matches non-major)", ruleIndices: [12], input: { manager: "regex", updateType: "minor", depName: "go", packageName: "golang.org/dl" }, expect: "needs-human", expectDashboardApproval: true },
  // Rule 15 (Go testdata fixtures are out of scope) matches on packageFile via matchFileNames —
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
  { name: "helm-values placeholder image in a nested Go testdata fixture (disabled, never looked up)", ruleIndices: [15], input: { manager: "helm-values", updateType: "minor", depName: "myregistry/app", packageName: "myregistry/app", packageFile: "pkg/cmd/tool/testdata/params/values.yaml" }, expect: "needs-human", expectEnabled: false, expectExtracted: false },
  { name: "helm-values placeholder image in a root-level testdata fixture (disabled, never looked up)", ruleIndices: [15], input: { manager: "helm-values", updateType: "minor", depName: "myregistry/app", packageName: "myregistry/app", packageFile: "testdata/values.yaml" }, expect: "needs-human", expectEnabled: false, expectExtracted: false },
  // Negative control for rule 15: the same dep outside any testdata tree must NOT be disabled.
  // `expectEnabled: undefined` with the key present opts into the assertion (key presence, same
  // convention as expectDashboardApproval) and pins the resolved value to "absent" — the preset
  // sets no top-level enabled, so anything else here means the rule over-matched. Also the
  // negative control for check 4: the file must survive extraction.
  { name: "helm-values image outside testdata (rule 12 must not match)", ruleIndices: [], input: { manager: "helm-values", updateType: "minor", depName: "myregistry/app", packageName: "myregistry/app", packageFile: "charts/app/values.yaml" }, expect: "needs-human", expectEnabled: undefined, expectExtracted: true },
  // A directory whose name merely contains "testdata" is not a testdata tree: both the rule's
  // globs and the ignorePaths entry are segment-anchored, and filterIgnoredFiles' substring
  // fallback (`file.includes(ignorePath)`) never matches a literal glob against a real path.
  { name: "gomod dep in a directory merely named like testdata (neither disabled nor dropped)", ruleIndices: [2, 20], input: { manager: "gomod", updateType: "patch", depName: "github.com/some/other", packageName: "github.com/some/other", packageFile: "pkg/testdata_helper/go.mod" }, expect: "unattended", expectEnabled: undefined, expectExtracted: true },
  // nuget is the one manager :ignoreModulesAndTests overrides (nuget.ignorePaths, which keeps
  // test/ and tests/ in scope), and getManagerConfig merges that override OVER the top-level
  // list, so the top-level **/testdata/** never reaches nuget on its own — the preset restates
  // nuget's list with the entry added. First case pins that; second pins that the restated copy
  // kept renovate's own nuget exception (test/ still extracted) instead of silently widening it.
  { name: "nuget project file in a root-level testdata fixture (dropped via the restated nuget override)", ruleIndices: [15], input: { manager: "nuget", updateType: "minor", depName: "Newtonsoft.Json", packageName: "Newtonsoft.Json", packageFile: "testdata/Fixture.csproj" }, expect: "needs-human", expectEnabled: false, expectExtracted: false },
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
  { name: "vulnerability alert on an automerging gomod patch (lane survives, still automerges)", ruleIndices: [2, 3, 20], input: { manager: "gomod", datasource: "go", updateType: "patch", depName: "k8s.io/api", packageName: "k8s.io/api" }, expect: "unattended", expectAutomerge: true },
  // The security lane: the vulnerabilityAlerts block forces automerge:true and the unattended lane
  // over whatever the authored rules resolved, and the alert defaults force
  // dependencyDashboardApproval:false, so a CVE fix opens unasked on a path that is otherwise
  // gated (minor, major) and merges on a green pipeline. The first-party case is the residual:
  // force wins over the internal group's automerge:false and no packageRule can tell an alert
  // apart, so an advisory on a first-party module would automerge too. Pinned as it is, so a
  // change in Renovate's force precedence fails here instead of going unnoticed.
  { name: "vulnerability alert on a dashboard-gated gomod minor (gate bypassed, security lane automerges)", ruleIndices: [1], input: { manager: "gomod", datasource: "go", updateType: "minor", depName: "golang.org/x/net", packageName: "golang.org/x/net" }, expect: "unattended", expectAutomerge: true, expectDashboardApproval: false },
  { name: "vulnerability alert on a kubernetes gomod minor (gate bypassed, security lane automerges)", ruleIndices: [1, 3], input: { manager: "gomod", datasource: "go", updateType: "minor", depName: "k8s.io/api", packageName: "k8s.io/api" }, expect: "unattended", expectAutomerge: true, expectDashboardApproval: false },
  { name: "vulnerability alert on a dashboard-gated major (gate bypassed, security lane automerges on a green pipeline)", ruleIndices: [14], input: { manager: "gomod", datasource: "go", updateType: "major", depName: "github.com/some/other", packageName: "github.com/some/other" }, expect: "unattended", expectAutomerge: true, expectDashboardApproval: false },
  { name: "vulnerability alert on a first-party minor (residual: force wins over automerge:false)", ruleIndices: [1, 7], input: { manager: "gomod", datasource: "go", updateType: "minor", depName: "github.com/go-kure/kure", packageName: "github.com/go-kure/kure" }, expect: "unattended", expectAutomerge: true, expectDashboardApproval: false },
  // Rule 15's enabled:false does NOT survive the synthetic rule: force.enabled:true clears the
  // skipReason rule 15 set and overwrites enabled (verified on 44.14.10, 44.42.0 and 44.65.3,
  // both the OSV and the GitHub-alert rule shapes). `expectEnabled: true` pins exactly that, so
  // the reason ignorePaths carries the guarantee stays a tested fact rather than a comment — if
  // this ever fails, renovate changed force precedence and the rule-12 description is stale.
  // `expectExtracted: false` is the guarantee itself: the file never reaches package rules.
  { name: "vulnerability alert on a gomod dep inside a testdata tree (force re-enables rule 12; extraction is what keeps it out)", ruleIndices: [2, 15, 20], input: { manager: "gomod", datasource: "go", updateType: "patch", depName: "github.com/some/vulnerable", packageName: "github.com/some/vulnerable", packageFile: "pkg/foo/testdata/mod/go.mod" }, expect: "unattended", expectEnabled: true, expectExtracted: false },
];

// Consumer-effective cases (go-kure/.github#217, go-kure/kure#813): the checks above resolve the
// shared preset alone, but a real repo's renovate.json extends it and then appends its own
// packageRules, which a real run concatenates AFTER the preset's array (extends resolves first;
// consumer rules are later array members, so they can override a scalar the preset set, same
// later-overwrites-earlier rule as within the preset itself). A consumer override can silently
// defeat the trusted lane's whole point — bundling tier 1/2 with tier 3 back onto one branch — in
// a way none of the checks above can see, because they never load a consumer file. Each case's
// `consumerRules` is spliced onto `preset.packageRules` exactly the way `extends` + local
// packageRules composes in a real run.
const CONSUMER_MATRIX = [
  {
    name: "kure's CURRENT renovate.json override still re-merges go-kure/.github into the plain group (go-kure/kure#813 not yet applied)",
    consumerRules: [
      {
        matchDepNames: ["go-kure/.github"],
        groupName: "github-actions",
        postUpgradeTasks: { commands: ["./scripts/vendor-guard.sh"], fileFilters: ["site/scripts/check-forbidden-terms.sh"], executionMode: "branch" },
      },
    ],
    input: { manager: "github-actions", updateType: "digest", depName: "go-kure/.github", packageName: "go-kure/.github" },
    // automerge itself survives (the consumer rule sets no automerge key, so rule 16's automerge:
    // true stands), but groupName resolves back to the plain "github-actions" group tier 3 also
    // shares — the exact defeat go-kure/kure#813 exists to fix, pinned here so a fix to the
    // preset alone can never be mistaken for a fix to this.
    expect: "unattended",
    expectGroupName: "github-actions",
  },
  {
    name: "kure's PROPOSED renovate.json (go-kure/kure#813 applied) keeps go-kure/.github in the trusted group",
    consumerRules: [
      {
        matchDepNames: ["go-kure/.github"],
        postUpgradeTasks: { commands: ["./scripts/vendor-guard.sh"], fileFilters: ["site/scripts/check-forbidden-terms.sh"], executionMode: "branch" },
      },
    ],
    input: { manager: "github-actions", updateType: "digest", depName: "go-kure/.github", packageName: "go-kure/.github" },
    expect: "unattended",
    expectGroupName: "github-actions-trusted",
  },
  {
    name: "launcher's current renovate.json has no override at all — the trusted lane applies untouched",
    consumerRules: [],
    input: { manager: "github-actions", updateType: "minor", depName: "actions/checkout", packageName: "actions/checkout" },
    expect: "unattended",
    expectGroupName: "github-actions-trusted",
  },
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
  // Same key-presence opt-in and Boolean() comparison as expectDashboardApproval: the preset sets
  // no top-level separateMinorPatch, so a case no Go rule matches resolves it to undefined.
  if ("expectSeparateMinorPatch" in c && Boolean(result.separateMinorPatch) !== Boolean(c.expectSeparateMinorPatch)) {
    console.error(`FAIL [outcome] ${c.name}: expected separateMinorPatch=${c.expectSeparateMinorPatch}, got ${result.separateMinorPatch}`);
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
  // The lane label proves automerge eligibility, not which BRANCH a dep lands on — two rules can
  // both automerge yet still be safe to bundle only if Renovate would ever group them onto one
  // branch, and Renovate ANDs automerge across every member of a grouped branch (go-minor's
  // description above). groupName is the resolved value that answers that: two deps sharing one
  // groupName share one branch. Opt-in on key presence, strict comparison — same convention as
  // expectEnabled — so a rule that silently stopped setting its own groupName (falling through to
  // an earlier or later rule's value) fails loudly instead of merely losing test coverage.
  if ("expectGroupName" in c && result.groupName !== c.expectGroupName) {
    console.error(`FAIL [outcome] ${c.name}: expected groupName=${JSON.stringify(c.expectGroupName)}, got ${JSON.stringify(result.groupName)}`);
    failures++;
  }
  // Strict and key-presence opt-in, like expectEnabled: a case that expects no hold pins the
  // value to undefined, because the preset sets no top-level minimumReleaseAge.
  if ("expectMinimumReleaseAge" in c && result.minimumReleaseAge !== c.expectMinimumReleaseAge) {
    console.error(`FAIL [outcome] ${c.name}: expected minimumReleaseAge=${JSON.stringify(c.expectMinimumReleaseAge)}, got ${JSON.stringify(result.minimumReleaseAge)}`);
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

// Check 5 — consumer-effective. Not scoped to touchedIndices/coverage: consumerRules are spliced
// onto a CLONE of preset.packageRules for each case, never onto the shared array these indices
// index into, so this loop cannot contribute to (or corrupt) check 1's per-rule coverage.
for (const c of CONSUMER_MATRIX) {
  const input = {
    ...preset,
    packageRules: [...preset.packageRules, ...c.consumerRules],
    ...c.input,
  };
  const result = await applyPackageRules(input);
  const labelSet = new Set([...(result.labels ?? []), ...(result.addLabels ?? [])]);
  const lanes = LANES.filter((l) => labelSet.has(l));
  if (lanes.length !== 1) {
    console.error(`FAIL [consumer-outcome] ${c.name}: expected exactly one lane, got [${lanes.join(", ")}] (labels=${JSON.stringify(result.labels)})`);
    failures++;
    continue;
  }
  if (lanes[0] !== c.expect) {
    console.error(`FAIL [consumer-outcome] ${c.name}: expected ${c.expect}, got ${lanes[0]}`);
    failures++;
  }
  if ("expectGroupName" in c && result.groupName !== c.expectGroupName) {
    console.error(`FAIL [consumer-outcome] ${c.name}: expected groupName=${JSON.stringify(c.expectGroupName)}, got ${JSON.stringify(result.groupName)}`);
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
// Drift guard: for the plain list and for every manager EITHER side overrides — the installed
// renovate's own :ignoreModulesAndTests, or the preset — the effective resolved list must still
// carry every entry of the effective inherited one. The preset restates those lists in full to
// add one entry, and this is what catches a restated copy drifting from the inherited one.
// Iterating the preset's overrides too, not only the inherited ones, is what catches a restated
// override outliving the upstream one it shadows: the inherited effective list for that manager
// then falls back to the top-level eight, and the six-entry restated copy fails on __tests__/,
// test/ and tests/. Walking only the inherited side would skip that manager entirely.
for (const m of new Set([PLAIN_MANAGER, ...overrideManagersOf(inheritedResolved), ...overrideManagersOf(resolvedPreset)])) {
  const inherited = effectiveIgnorePaths(inheritedResolved, m);
  const resolved = effectiveIgnorePaths(resolvedPreset, m);
  for (const p of inherited) {
    if (!resolved.includes(p)) {
      console.error(`FAIL [extraction] effective ignorePaths for manager ${m} lacks inherited entry ${JSON.stringify(p)} — the preset's restated list has drifted from renovate's :ignoreModulesAndTests, or the upstream override it restates is gone and the restated copy now shadows the top-level list on its own (installed effective list for ${m}: ${JSON.stringify(inherited)}, resolved: ${JSON.stringify(resolved)}); restate the current upstream list, or drop the override if upstream no longer has one`);
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

// Check 6 — update-type oracle. The lanes route on updateType, so how Renovate classifies a
// pre-release bump and a pseudo-version decides which lane a real bump lands in. Measured on
// 44.101.2: classifyRelease compares only the major and the minor, so a bump inside one
// pre-release line (rc.2 to rc.3) and the step from the last pre-release to the final release are
// both "patch" — a core library on a pre-release would automerge its rc bumps (a first-party
// patch opens a pull request, never automerges); a Go pseudo-version that replaces another
// v0.0.0- pseudo-version is "digest" (gomod only, set in lookup/index.js, pinned below by its
// source text because no function exposes it). A Renovate upgrade that reclassifies any of these
// fails here instead of moving a bump to another lane unnoticed.
const UPDATE_TYPE_CASES = [
  { from: "v0.2.0-rc.2", to: "v0.2.0-rc.3", expect: "patch" },
  { from: "v0.2.0-rc.3", to: "v0.2.0", expect: "patch" },
  { from: "v0.1.9", to: "v0.2.0-rc.1", expect: "minor" },
  { from: "v0.2.0", to: "v1.0.0", expect: "major" },
  { from: "v0.2.0", to: "v0.2.1-0.20261118000000-abcdef123456", expect: "patch" },
  { from: "v0.0.0-20261001000000-aaaaaaaaaaaa", to: "v0.0.0-20261118000000-bbbbbbbbbbbb", expect: "patch" },
];
const semverApi = getVersioning("semver");
for (const u of UPDATE_TYPE_CASES) {
  const got = classifyRelease(semverApi, u.from, u.to);
  if (got !== u.expect) {
    console.error(`FAIL [update-type] ${u.from} to ${u.to}: expected ${u.expect}, got ${got}`);
    failures++;
  }
}
// The condition AND the assignment it guards: a source that keeps the condition and assigns
// another type would pass a condition-only pin, so the assignment is part of the pattern, and the
// control runs the same pattern over a copy with the assignment changed, which must not match.
// Renovate writes the pseudo-version test in two forms: up to 44.101.2 `<value>?.startsWith("v0.0.0-")`
// on both values, from 44.251.0 `isPseudoVersion(<value>)` on both. Each side accepts either form, so
// the pin holds at every pin the harness runs against and still fails when the condition goes away.
const PSEUDO_SIDE = String.raw`(?:XX\?\.startsWith\("v0\.0\.0-"\)|isPseudoVersion\(XX\))`;
const PSEUDO_DIGEST_PIN = new RegExp(
  String.raw`config\.manager === "gomod" && ` + PSEUDO_SIDE.replaceAll("XX", "compareValue") + String.raw` && ` +
  PSEUDO_SIDE.replaceAll("XX", "update\\.newValue") + String.raw` && config\.currentDigest !== update\.newDigest\) \{\s*update\.updateType = "digest";`);
// A bare package specifier (no module entry argument) is not a URL: resolve it the way import()
// does before reading the file; an explicit entry is already a file URL.
const lookupUrl = lookupModuleSpecifier.startsWith("file:") ? lookupModuleSpecifier : import.meta.resolve(lookupModuleSpecifier);
const lookupSource = readFileSync(new URL(lookupUrl), "utf8");
if (!PSEUDO_DIGEST_PIN.test(lookupSource)) {
  console.error('FAIL [update-type] lookup/index.js no longer reclassifies a gomod v0.0.0- pseudo-version bump as "digest" with that condition and assignment; re-read how a pseudo-version bump is classified and update this check and the preset descriptions');
  failures++;
}
if (PSEUDO_DIGEST_PIN.test(lookupSource.replace('update.updateType = "digest";', 'update.updateType = "major";'))) {
  console.error('FAIL [update-type-control] the pseudo-version pin still matches a source whose assignment was changed to "major"; the pin cannot fail');
  failures++;
}
// Check 8 — candidate selection. Renovate reads separateMinorPatch at lookup, before any
// update-type rule, and sorts the candidate releases into buckets: with it off, a patch and a
// minor of one dependency share the "non-major" bucket and only the highest is offered, so the
// patch lane would never see a patch while a minor exists (the dashboard-gated minor hides it).
// Resolve the preset for a dependency WITHOUT an update type (the config lookup sees), run
// Renovate's own getBucket for a patch and a minor release, and require two buckets, for each
// manager the lanes route. The control drops the flag from the resolved config and must see one.
const { getBucket } = await import(distRoot("workers/repository/process/lookup/bucket.js"));
const BUCKET_CASES = [
  { manager: "npm", depName: "some-pkg" },
  { manager: "dockerfile", depName: "alpine" },
  { manager: "gomod", depName: "github.com/some/other" },
  { manager: "gomod", depName: "k8s.io/api" },
  { manager: "gomod", depName: "github.com/go-kure/kure" },
  { manager: "regex", depName: "git-cliff" },
  { manager: "github-actions", depName: "some-org/some-action" },
  { manager: "mise", depName: "yq" },
];
let bucketCases = 0;
for (const b of BUCKET_CASES) {
  bucketCases++;
  const lookupConfig = await applyPackageRules({ ...preset, ...b, packageName: b.packageName ?? b.depName });
  const bucket = (cfg, to) => getBucket({ separateMajorMinor: true, ...cfg }, "1.2.3", to, semverApi);
  const patchBucket = bucket(lookupConfig, "1.2.4");
  const minorBucket = bucket(lookupConfig, "1.3.0");
  if (patchBucket === minorBucket) {
    console.error(`FAIL [bucket] ${b.manager} ${b.depName}: a patch (1.2.4) and a minor (1.3.0) of 1.2.3 share the bucket "${patchBucket}"; only one is offered and the patch never reaches its lane`);
    failures++;
  }
  const { separateMinorPatch: _dropped, ...without } = lookupConfig;
  if (bucket(without, "1.2.4") !== bucket(without, "1.3.0")) {
    console.error(`FAIL [bucket-control] ${b.manager} ${b.depName}: without separateMinorPatch the patch and the minor should share a bucket; the check cannot fail`);
    failures++;
  }
}
// Check 7 — branch partition. Renovate puts every update of one group on one branch, automerges
// the branch only when every member automerges (generate.ts: `every`) and holds it for
// dashboard approval when any member needs it (`some`), so a patch (automerge) sharing a branch
// with a minor (gate) is held by the minor. Resolve a patch and a minor of one group through the
// preset, run Renovate's own generateBranchName on each, and require two different branches. The
// control strips separateMinorPatch from the resolved config and must see ONE branch, so this
// check can fail.
const branchOf = async (input, drop) => {
  const resolved = await applyPackageRules({ ...preset, ...input, packageName: input.packageName ?? input.depName });
  const update = {
    ...resolved,
    ...input,
    newMajor: 1,
    newMinor: 2,
    branchPrefix: "renovate/",
    additionalBranchPrefix: "",
    branchTopic: "{{{depNameSanitized}}}",
    branchName: "{{{branchPrefix}}}{{{additionalBranchPrefix}}}{{{branchTopic}}}",
    separateMajorMinor: true,
    group: { branchTopic: "{{{groupSlug}}}", branchName: "{{{branchPrefix}}}{{{additionalBranchPrefix}}}{{{branchTopic}}}" },
  };
  if (drop) delete update.separateMinorPatch;
  generateBranchName(update);
  return update.branchName;
};
const PARTITION_CASES = [
  { name: "kubernetes", patch: { manager: "gomod", updateType: "patch", depName: "k8s.io/api" }, minor: { manager: "gomod", updateType: "minor", depName: "k8s.io/client-go" } },
  { name: "sigs.k8s.io", patch: { manager: "gomod", updateType: "patch", depName: "sigs.k8s.io/controller-runtime" }, minor: { manager: "gomod", updateType: "minor", depName: "sigs.k8s.io/yaml" } },
  { name: "fluxcd", patch: { manager: "gomod", updateType: "patch", depName: "github.com/fluxcd/pkg/oci" }, minor: { manager: "gomod", updateType: "minor", depName: "github.com/fluxcd/pkg/apis" } },
  { name: "cloudnative-pg", patch: { manager: "gomod", updateType: "patch", depName: "github.com/cloudnative-pg/machinery" }, minor: { manager: "gomod", updateType: "minor", depName: "github.com/cloudnative-pg/cnpg-i" } },
  { name: "internal (first-party)", patch: { manager: "gomod", updateType: "patch", depName: "github.com/go-kure/kure" }, minor: { manager: "gomod", updateType: "minor", depName: "github.com/go-kure/launcher" } },
];
let partitionCases = 0;
for (const p of PARTITION_CASES) {
  partitionCases++;
  const patchBranch = await branchOf(p.patch, false);
  const minorBranch = await branchOf(p.minor, false);
  if (patchBranch === minorBranch) {
    console.error(`FAIL [partition] ${p.name}: a patch and a minor share the branch ${patchBranch}; the patch would wait on the minor's gate or automerge setting`);
    failures++;
  }
  const controlPatch = await branchOf(p.patch, true);
  if (controlPatch !== minorBranch) {
    console.error(`FAIL [partition-control] ${p.name}: without separateMinorPatch the patch branch (${controlPatch}) should equal the minor branch (${minorBranch}); the check cannot fail, so it proves nothing`);
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
// index.ts) over whichever rule already matched, so `labels` here silently
// replaces the resolved lane. That is the security lane's whole mechanism
// (an alert merges unattended), so it is allowed only as a complete pair:
// automerge:true with labels that carry unattended and never needs-human.
// Either half alone would split the lane from the merge behaviour.
// addLabels may not carry a lane term.
if (preset.vulnerabilityAlerts) {
  const va = preset.vulnerabilityAlerts;
  const vaLabels = va.labels ?? [];
  if ("labels" in va && (va.automerge !== true || !vaLabels.includes("unattended") || vaLabels.includes("needs-human"))) {
    console.error("FAIL [structural] vulnerabilityAlerts sets `labels` without the complete security-lane pair (automerge:true, labels with unattended and no needs-human), which force-replaces the resolved lane");
    failures++;
  }
  if (va.automerge === true && !vaLabels.includes("unattended")) {
    console.error("FAIL [structural] vulnerabilityAlerts has automerge:true but no unattended label");
    failures++;
  }
  if ((va.addLabels ?? []).some((l) => LANES.includes(l))) {
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
console.log(`renovate-lane-policy-test: OK (${MATRIX.length} matrix cases, ${VULN_MATRIX.length} vuln cases, ${CONSUMER_MATRIX.length} consumer-effective cases, ${extractionCases} extraction cases, ${UPDATE_TYPE_CASES.length} update-type cases, ${partitionCases} branch-partition cases, ${bucketCases} candidate-bucket cases, ${ruleCount} packageRules all covered)`);
