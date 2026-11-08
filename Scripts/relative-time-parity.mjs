#!/usr/bin/env node
// relative-time-parity.mjs — the JS half of the relative-time pin (finding F5,
// Task 1.4).
//
// `relLabel` in Sources/ArcWebUI/Assets/overlay.js and `AppState.relTimeLabel`
// in Sources/ArcWebUI/Views.swift are the same ladder written twice, on purpose:
// the server paints the first frame, the page repaints the labels every 60 s
// without a round-trip, so neither side can own the other. duplication that
// cannot be deleted can only be pinned, and a pin is only a pin if it lives on
// both sides — `Tests/ArcAgentWebUITests/RelativeTimeParityTests.swift` asserts
// the Swift ladder against the same table.
//
// this harness reads the shared golden (`relative-time-golden.tsv`), extracts
// `relLabel` from the real overlay by brace matching (no import: the overlay is
// a browser script, not a module), and evaluates it under a FROZEN clock. the
// function calls `new Date()` for "now", so the freeze is a substituted `Date`
// binding in the function's own scope rather than a mutated global — nothing
// else in the process sees a fake clock.
//
// every row must equal its `expected` column. those literals were derived by
// hand from the documented ladder (see the TSV header), never by running either
// implementation, so this run and the Swift run are two independent checks
// against one authority instead of two implementations vouching for each other.
//
// zero dependencies: node stdlib only, Node >= 22, matching the convention in
// Scripts/README-gates.md (native fetch/WebSocket, no npm).
//
// usage: node Scripts/relative-time-parity.mjs [--golden=<path>] [--overlay=<path>]
// exit:  0 every row matched · 1 any mismatch, empty table, or unreadable input
//        2 bad arguments

import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, '..');

const DEFAULTS = {
  golden: join(REPO_ROOT, 'Tests/ArcAgentWebUITests/Fixtures/relative-time-golden.tsv'),
  overlay: join(REPO_ROOT, 'Sources/ArcWebUI/Assets/overlay.js'),
};

function printUsage() {
  console.error('usage: node Scripts/relative-time-parity.mjs [--golden=<path>] [--overlay=<path>]');
}

function parseArgs(argv) {
  const out = { ...DEFAULTS };
  for (const arg of argv) {
    if (arg === '--help' || arg === '-h') {
      printUsage();
      process.exit(0);
    }
    const flag = /^--(golden|overlay)=(.+)$/.exec(arg);
    if (!flag) {
      console.error(`unknown argument: ${arg}`);
      printUsage();
      process.exit(2);
    }
    out[flag[1]] = resolve(flag[2]);
  }
  return out;
}

// ---- the table -----------------------------------------------------------

function readRows(path) {
  const text = readFileSync(path, 'utf8');
  const rows = [];
  const lines = text.split('\n');
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index].replace(/\r$/, '');
    if (line.trim() === '' || line.startsWith('#')) continue;
    const fields = line.split('\t');
    if (fields.length === 3 && fields[0] === 'now_ms' && fields[1] === 'then_ms') continue;
    const lineNo = index + 1;
    if (fields.length !== 3) {
      throw new Error(`${path}:${lineNo}: expected 3 tab-separated columns (now_ms, then_ms, expected), got ${fields.length}`);
    }
    const [nowRaw, thenRaw, expected] = fields;
    const nowMs = Number(nowRaw);
    const thenMs = Number(thenRaw);
    if (!Number.isFinite(nowMs) || !Number.isFinite(thenMs)) {
      throw new Error(`${path}:${lineNo}: non-numeric epoch column (now_ms="${nowRaw}", then_ms="${thenRaw}")`);
    }
    if (expected === '') {
      throw new Error(`${path}:${lineNo}: empty expected label`);
    }
    rows.push({ line: lineNo, nowMs, thenMs, expected });
  }
  return rows;
}

// ---- the ladder, lifted out of the served overlay ------------------------

/// brace-match `function <name>(` out of the overlay. string and comment
/// skipping matters because the body carries month-name literals; a naive
/// brace counter happens to survive this one, which is exactly why a body that
/// grows a brace inside a string must not be able to break the pin silently.
function extractFunction(source, name) {
  const anchor = `function ${name}(`;
  const start = source.indexOf(anchor);
  if (start < 0) {
    throw new Error(`overlay: no \`${anchor}\` — the ladder was renamed or removed; re-point the harness before trusting this gate`);
  }
  let i = source.indexOf('{', start);
  if (i < 0) throw new Error(`overlay: no body after \`${anchor}\``);
  let depth = 0;
  while (i < source.length) {
    const ch = source[i];
    if (ch === '/' && source[i + 1] === '/') {
      const nl = source.indexOf('\n', i + 2);
      if (nl < 0) break;
      i = nl + 1;
      continue;
    }
    if (ch === '/' && source[i + 1] === '*') {
      const close = source.indexOf('*/', i + 2);
      if (close < 0) break;
      i = close + 2;
      continue;
    }
    if (ch === '"' || ch === "'" || ch === '`') {
      const quote = ch;
      i += 1;
      while (i < source.length) {
        if (source[i] === '\\') { i += 2; continue; }
        if (source[i] === quote) { i += 1; break; }
        i += 1;
      }
      continue;
    }
    if (ch === '{') {
      depth += 1;
    } else if (ch === '}') {
      depth -= 1;
      if (depth === 0) return source.slice(start, i + 1);
    }
    i += 1;
  }
  throw new Error(`overlay: unbalanced braces after \`${anchor}\``);
}

// ---- the frozen clock ----------------------------------------------------

/// `relLabel` reads "now" as `new Date()`. handing it a `Date` binding whose
/// zero-argument constructor resolves to `fixedNowMs` freezes exactly that read
/// and leaves `new Date(ms)` and `new Date(y, m, d)` (the midnight arithmetic)
/// as real local-time Dates, which is what the ladder means by a calendar day.
function frozenDateClass(fixedNowMs) {
  const RealDate = Date;
  function FakeDate(...args) {
    if (!new.target) {
      throw new Error('relLabel called Date() without `new`; the freeze models the constructor form only');
    }
    return args.length ? new RealDate(...args) : new RealDate(fixedNowMs);
  }
  FakeDate.now = () => fixedNowMs;
  FakeDate.parse = RealDate.parse;
  FakeDate.UTC = RealDate.UTC;
  FakeDate.prototype = RealDate.prototype;
  return FakeDate;
}

function ladderFrom(overlaySource) {
  const source = extractFunction(overlaySource, 'relLabel');
  // the evaluated body is a function declaration; `new Function` returns it.
  return new Function('Date', `"use strict";\nreturn (${source});`);
}

// ---- run -----------------------------------------------------------------

function main() {
  const args = parseArgs(process.argv.slice(2));
  console.log(`golden: ${args.golden}`);
  console.log(`overlay: ${args.overlay}`);

  let rows;
  try {
    rows = readRows(args.golden);
  } catch (error) {
    console.error(`relative-time parity: cannot read the golden — ${error.message}`);
    process.exit(1);
  }
  if (rows.length === 0) {
    // a table that parsed to nothing would otherwise report "0 mismatches".
    console.error('relative-time parity: the golden has 0 data rows — refusing to report a vacuous pass');
    process.exit(1);
  }

  let ladderFactory;
  try {
    ladderFactory = ladderFrom(readFileSync(args.overlay, 'utf8'));
  } catch (error) {
    console.error(`relative-time parity: cannot load the JS ladder — ${error.message}`);
    process.exit(1);
  }

  let mismatches = 0;
  for (const row of rows) {
    let got;
    try {
      // one factory call per row: each row freezes its own `now_ms`.
      got = ladderFactory(frozenDateClass(row.nowMs))(row.thenMs);
    } catch (error) {
      mismatches += 1;
      console.log(`MISMATCH row ${row.line} (now_ms ${row.nowMs}, then_ms ${row.thenMs}): expected "${row.expected}", the ladder threw — ${error.message}`);
      continue;
    }
    if (got !== row.expected) {
      mismatches += 1;
      console.log(`MISMATCH row ${row.line} (now_ms ${row.nowMs}, then_ms ${row.thenMs}): expected "${row.expected}", got "${got}"`);
    }
  }

  const noun = mismatches === 1 ? 'mismatch' : 'mismatches';
  console.log(`relative-time parity: ${rows.length} rows, ${mismatches} ${noun}`);
  process.exit(mismatches === 0 ? 0 : 1);
}

main();
