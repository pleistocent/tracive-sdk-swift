#!/usr/bin/env node
// Public-hygiene check.
//
// This repository is published. Nothing in it — code, comments, docs, test names, error strings
// or commit messages — may name an internal repository, an internal design document, a backend
// commit, a backend source path or symbol, a server-side function name, the backend's database
// product, an internal collection path, or non-English roadmap phase jargon. Say "the Tracive
// API", "the server", "record key", "phase 1 / phase 2".
//
// WHAT THIS SCRIPT ACTUALLY CHECKS: the working tree only. Every text file is scanned, including
// extension-less ones such as LICENSE and dotfiles such as .gitignore — it used to skip both,
// because it keyed on a known-extension list.
//
// COMMIT MESSAGES ARE NOT SCANNED, and the rule still covers them. Git history is not read here
// at all. Two reasons it stays that way: a CI checkout is shallow by default, so a history scan
// would silently cover one commit while appearing to cover all of them; and a message that
// DESCRIBES one of these rules trips it, exactly as this file would if it did not exempt itself.
// Commit messages are a review responsibility — see CONTRIBUTING.md.
//
// A note on how this script is written, because it is not obvious: it checks CATEGORIES and
// SHAPES rather than embedding the literal internal names. Writing those names into a public
// repository's tooling would leak exactly what the rule exists to protect — the denylist would
// become the disclosure. The infrastructure-vendor list below deliberately names many vendors,
// so it asserts nothing about which one is real.
//
// The literal term list lives in `scripts/hygiene-terms.txt`, which is TRACKED. It used to be an
// untracked `.hygiene-forbidden`, and that made the `forbidden_token` category empty on every CI
// run — a clean checkout cannot contain an untracked file — so the one category advertised as
// catching internal repository names, design-doc titles and server-side function names could
// never fire. A check that cannot fail is worse than no check, because it reads as coverage.
//
// Tracking it does not reintroduce the disclosure problem, because every entry names a shape, a
// public framework API, a file-layout convention or a dictionary word. See the header of that
// file. A private, environment-specific list may still be added out of band in an untracked
// `.hygiene-forbidden`; it is purely additive and its absence can no longer empty a category.
//
// Before scanning anything, this script proves every rule can still fire, by running all of them
// against `scripts/hygiene-selftest.txt` and refusing to continue if any rule matches nothing.
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { dirname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = process.cwd();
const SCRIPT_DIRECTORY = dirname(fileURLToPath(import.meta.url));
const TERMS_PATH = join(SCRIPT_DIRECTORY, 'hygiene-terms.txt');
const SELF_TEST_PATH = join(SCRIPT_DIRECTORY, 'hygiene-selftest.txt');
const SELF = 'Scripts/check-hygiene.js';
// Files whose whole purpose is to contain forbidden-looking text. `.hygiene-forbidden` is the
// private list: it is untracked, it holds the real internal names, and scanning it would report
// every one of them as a violation of itself.
const SCANNER_OWN_FILES = new Set([
  'Scripts/hygiene-terms.txt',
  'Scripts/hygiene-selftest.txt',
  '.hygiene-forbidden',
]);

/** Anything larger, or holding a NUL in its first block, is treated as binary and skipped. */
const MAX_SCANNED_BYTES = 2_000_000;

const SKIP_DIRECTORIES = new Set(['.build', '.git', 'Pods', 'DerivedData', '.swiftpm']);
// Extensions scanned without sniffing. A file with no extension, or a dotfile, is sniffed
// instead — see `looksLikeText` — because LICENSE, .gitignore and .npmrc are all plain text that
// this script used to walk straight past.
const TEXT_EXTENSIONS = new Set(['.swift', '.md', '.yml', '.yaml', '.json', '.plist', '.sh', '.entitlements', '.sha256']);

// The one allowed exception, and the only permitted matches for the org token.
//
// Matched as patterns with a trailing lookahead rather than as plain substrings, because a
// substring allowance is also a PREFIX allowance: allowing `com.pleistocent.tracive` as a
// substring silently allowed every id built on top of it, including non-production variants that
// appear nowhere in shipping code and whose only effect here would be to disclose that they
// exist. The repository path carries an optional `.git`, which package.json's clone URL has.
const ALLOWED_PLEISTOCENT_PATTERNS = [
  // The copyright holder in a licence header. Legitimate, and the reason widening this scan to
  // extension-less files surfaced LICENSE on the first run.
  /Copyright \d{4} (?:PT )?Pleistocent(?:[A-Za-z ]*)?(?![A-Za-z0-9._-])/g,
  /com\.pleistocent\.tracive(?![A-Za-z0-9._-])/g,
  /github\.com\/pleistocent\/tracive-sdk-swift(\.git)?(?![A-Za-z0-9._-])/g,
  /pleistocent\/tracive-sdk-swift(?![A-Za-z0-9._-])/g,
];

const RULES = [
  {
    code: 'backend_commit_sha',
    // A 40-character hex run is a git object id. Nothing legitimate in this repository is one:
    // the fixture hash is 64 characters and lives in an allowlisted line.
    pattern: /\b[0-9a-f]{40}\b/g,
    message: 'looks like a backend commit id',
  },
  {
    code: 'infrastructure_vendor',
    // Backend infrastructure naming, of any flavour, does not belong in a public client SDK.
    pattern:
      /\b(firestore|firebase|cloudfunctions|cloud function|dynamodb|bigtable|cosmosdb|mongodb|supabase|planetscale|rds\.amazonaws)\b/gi,
    message: 'names backend infrastructure; say "the Tracive API" or "the server"',
  },
  {
    code: 'internal_collection_path',
    pattern: /\b(collection|doc)\(\s*['"`][a-z_/-]+['"`]\s*\)/gi,
    message: 'looks like an internal database collection path',
  },
  {
    code: 'internal_document_reference',
    pattern: /\b(internal design doc|design doc:|RFC-INT|internal spec)\b/gi,
    message: 'references an internal document',
  },
];

function parseTermList(text, origin) {
  return text
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line !== '' && !line.startsWith('#'))
    .map((line) => {
      const asRegex = /^\/(.*)\/([a-z]*)$/.exec(line);
      return {
        code: 'forbidden_token',
        source: `${origin}: ${line}`,
        pattern: asRegex
          ? new RegExp(asRegex[1], asRegex[2].includes('g') ? asRegex[2] : `${asRegex[2]}g`)
          : new RegExp(line.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'gi'),
        message: 'matches a forbidden internal token',
      };
    });
}

function loadTrackedTerms() {
  if (!existsSync(TERMS_PATH)) {
    console.error(
      `check-hygiene: ${relative(ROOT, TERMS_PATH)} is missing. It is tracked precisely so that ` +
        'the forbidden-token category cannot be silently empty; restore it rather than deleting ' +
        'the step.',
    );
    process.exit(1);
  }
  const terms = parseTermList(readFileSync(TERMS_PATH, 'utf8'), 'hygiene-terms.txt');
  if (terms.length === 0) {
    console.error(
      `check-hygiene: ${relative(ROOT, TERMS_PATH)} contains no entries, so the ` +
        'forbidden-token category would pass everything.',
    );
    process.exit(1);
  }
  return terms;
}

/** Optional, untracked, purely additive. Absence is fine; it can no longer empty a category. */
function loadPrivateTerms() {
  const path = join(ROOT, '.hygiene-forbidden');
  if (!existsSync(path)) return [];
  return parseTermList(readFileSync(path, 'utf8'), '.hygiene-forbidden');
}

/**
 * Every rule must match at least one line of the self-test corpus. A rule that matches nothing
 * there is a rule that has stopped working — a mistyped regex, a category quietly emptied — and
 * the whole point of this script is that such a thing must not pass as coverage.
 */
function proveEveryRuleCanFire(rules) {
  if (!existsSync(SELF_TEST_PATH)) {
    console.error(
      `check-hygiene: ${relative(ROOT, SELF_TEST_PATH)} is missing, so no rule in this script ` +
        'has been shown to detect anything.',
    );
    process.exit(1);
  }
  const corpus = readFileSync(SELF_TEST_PATH, 'utf8').split('\n');
  const dead = [];

  for (const rule of rules) {
    const fired = corpus.some((line) => {
      rule.pattern.lastIndex = 0;
      return rule.pattern.test(line);
    });
    if (!fired) dead.push(rule.source ?? rule.code);
  }
  if (!corpus.some((line) => checkPleistocent(line))) dead.push('organisation_token');

  if (dead.length > 0) {
    console.error('check-hygiene: these rules matched nothing in the self-test corpus:\n');
    for (const entry of dead) console.error(`  ${entry}`);
    console.error(
      `\nEither the rule is broken, or ${relative(ROOT, SELF_TEST_PATH)} is missing a probe for ` +
        'it. A rule that cannot fire is not a check.',
    );
    process.exit(1);
  }
}

function looksLikeText(path, stats) {
  if (stats.size > MAX_SCANNED_BYTES) return false;
  let contents;
  try {
    contents = readFileSync(path);
  } catch {
    return false;
  }
  const limit = Math.min(contents.length, 4096);
  for (let i = 0; i < limit; i++) {
    if (contents[i] === 0) return false;
  }
  return true;
}

function walk(directory, files = []) {
  for (const entry of readdirSync(directory)) {
    if (SKIP_DIRECTORIES.has(entry)) continue;
    const path = join(directory, entry);
    let stats;
    try {
      stats = statSync(path);
    } catch {
      continue;
    }
    if (stats.isDirectory()) {
      walk(path, files);
    } else {
      const dot = entry.lastIndexOf('.');
      // `dot <= 0` covers both `LICENSE` (no dot) and `.gitignore` (dot at index 0).
      const known = dot > 0 && TEXT_EXTENSIONS.has(entry.slice(dot));
      if (known || (dot <= 0 && looksLikeText(path, stats))) files.push(path);
    }
  }
  return files;
}

function checkPleistocent(line) {
  let remaining = line;
  for (const allowed of ALLOWED_PLEISTOCENT_PATTERNS) {
    allowed.lastIndex = 0;
    remaining = remaining.replace(allowed, '');
  }
  return /pleistocent/i.test(remaining);
}

const rules = [
  ...RULES.map((rule) => ({ ...rule, source: rule.code })),
  ...loadTrackedTerms(),
  ...loadPrivateTerms(),
];
proveEveryRuleCanFire(rules);

const violations = [];

for (const path of walk(ROOT)) {
  const relativePath = relative(ROOT, path);
  if (relativePath === SELF) continue; // this file quotes the patterns in order to state them
  if (SCANNER_OWN_FILES.has(relativePath)) continue; // they exist to contain forbidden text

  const lines = readFileSync(path, 'utf8').split('\n');
  lines.forEach((line, index) => {
    for (const rule of rules) {
      rule.pattern.lastIndex = 0;
      const match = rule.pattern.exec(line);
      if (match !== null) {
        violations.push({
          path: relativePath,
          line: index + 1,
          code: rule.code,
          detail: `${match[0]} — ${rule.message}`,
        });
      }
    }
    if (checkPleistocent(line)) {
      violations.push({
        path: relativePath,
        line: index + 1,
        code: 'organisation_token',
        detail:
          'the organisation token appears outside its allowed forms: the Android application id, ' +
          "and this repository's own GitHub path",
      });
    }
  });
}

if (violations.length > 0) {
  console.error('check-hygiene: public-hygiene violations found.\n');
  for (const violation of violations) {
    console.error(`  ${violation.path}:${violation.line}  [${violation.code}] ${violation.detail}`);
  }
  console.error(
    '\nUse "the Tracive API", "the server", "record key", "phase 1" / "phase 2" instead.',
  );
  process.exit(1);
}

console.log(`check-hygiene: clean (${rules.length} rules, each proven to fire).`);
