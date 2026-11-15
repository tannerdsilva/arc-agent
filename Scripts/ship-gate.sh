#!/usr/bin/env bash
# the consolidated ship gate — A17, the program's close.
#
# One command that re-asserts every slice's headline behaviour from fresh
# fixtures, so "the overlay is gone and the engine owns the client" is a
# measurement rather than a memory. Each row is one PASS/FAIL line; the script
# exits non-zero on any FAIL and prints the tally at the end.
#
# What it is checking, in order:
#
#   1  the file itself: `Assets/overlay.js` absent, no `.js` anywhere under
#      `Sources/`, and no source naming the deleted plumbing (the parameter,
#      the shipped asset, the generated declaration, the served url).
#   2  the manifest that embeds scripts into the binary: no types.
#   3  the SERVED document (a real request to the daemon): the engine's tags
#      and arc's sheet, and no `/ui/init.js`.
#   4  the suite (`make verify`: build + three test runs + the pin).
#   5  every gate group in `Scripts/ux-gates.mjs`, which is the behaviour the
#      program moved: focus first (it is the one group that must run on a
#      fresh daemon), then the rest.
#
# No row is exempt. The allowlist below was created for two pre-existing base
# defects (`tab budget`, `delete flow`); both pass now, so it is EMPTY — and the
# mechanism stays so that a future red row is named deliberately rather than
# inherited on the strength of an old comment. An empty list must not excuse
# anything: `grep -vE "^()"` matches every line, so the known-red branch is only
# reachable when the list is non-empty (see the guard below). Anything else is a
# FAIL.
#
# Requirements: a built daemon serving the UI on :8890 (`arc serve --webui`),
# `swift` on PATH, node >= 22. Override the page with ARC_UI_URL.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

UI="${ARC_UI_URL:-http://127.0.0.1:8890}"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"

FAILED=0
PASSED=0

pass() { printf '  [PASS] %s\n' "$1"; PASSED=$((PASSED + 1)); }
fail() { printf '  [FAIL] %s\n' "$1"; FAILED=$((FAILED + 1)); }

# known-red rows: named so any exemption is auditable. EMPTY after D8 — the two
# rows it used to carry (`tab budget`, `delete flow`) both pass now.
KNOWN_RED=''

printf 'ship gate — %s\n' "$UI"
printf '\n— the client is the engine —\n'

# 1. the file, the tree, the plumbing.
if [ -f Sources/ArcWebUI/Assets/overlay.js ]; then
	fail "Assets/overlay.js is absent"
else
	pass "Assets/overlay.js is absent"
fi

js_found=$(find Sources -name '*.js' -print -quit)
if [ -n "$js_found" ]; then
	fail "no .js under Sources/ (found $js_found)"
else
	pass "no .js under Sources/"
fi

# a comment may still describe the deleted file; nothing may REFERENCE it.
if grep -rqE 'overlay\.js|/ui/init\.js|overlayURL|Assets\.overlay|ArcOverlay' Sources/; then
	fail "no source names the deleted overlay plumbing"
else
	pass "no source names the deleted overlay plumbing"
fi

# 2. the manifest.
if grep -q '"types": \[\]' Sources/ArcWebUI/Assets/webui-assets.json; then
	pass "the asset manifest embeds nothing"
else
	fail "the asset manifest embeds nothing"
fi

# 3. the served document, from a real request.
#
# string matching, not `printf | grep -q`: with `pipefail` a `grep -q` that exits
# as soon as it matches sends SIGPIPE to printf, the pipeline reports 141, and the
# check reads false — which is exactly how the first run "passed" the absence row
# and failed both presence rows.
page=$(curl -fsS "$UI/" 2>/dev/null)
if [ -z "$page" ]; then
	fail "the daemon answers on $UI (start it: .build/debug/arc serve --webui)"
else
	case "$page" in
		*"/ui/init.js"*) fail "the served document carries no /ui/init.js" ;;
		*) pass "the served document carries no /ui/init.js" ;;
	esac
	case "$page" in
		*"/ui/webui-engine.js"*) pass "the served document still loads the engine" ;;
		*) fail "the served document still loads the engine" ;;
	esac
	case "$page" in
		*'href="/ui/style.css'*) pass "the served document still links arc's sheet" ;;
		*) fail "the served document still links arc's sheet" ;;
	esac
fi

# 4. the suite and the pin.
printf '\n— make verify —\n'
verify_log=$(mktemp -t ship-gate-verify)
if make verify >"$verify_log" 2>&1; then
	summaries=$(grep -E 'Test run with [0-9]+ tests' "$verify_log")
	if [ -z "$summaries" ]; then
		fail "make verify reports three test summaries"
	else
		total=$(printf '%s\n' "$summaries" | sed -nE 's/.*Test run with ([0-9]+) tests.*/\1/p' | awk '{s+=$1} END {print s}')
		printf '%s\n' "$summaries" | sed 's/^/      /'
		pass "make verify (three runs, $total tests)"
	fi
	pin=$(grep -E 'no-webui at ' "$verify_log" | tail -1)
	case "$pin" in
		*f286006*) pass "the pin is no-webui 3.1.0 at f286006 ($(printf '%s' "$pin" | sed 's/^ *//'))" ;;
		*) fail "the pin is no-webui 3.1.0 at f286006 (got: ${pin:-none})" ;;
	esac
else
	tail -25 "$verify_log" | sed 's/^/      /'
	fail "make verify"
fi
rm -f "$verify_log"

# 5. every gate group. focus first: it is the one group whose reads are
#    state-sensitive and it is measured on a fresh daemon.
printf '\n— ux gates —\n'
for group in focus residue composer theme draft drawer upload scroll interactions; do
	log=$(mktemp -t ship-gate-"$group")
	node Scripts/ux-gates.mjs --only="$group" >"$log" 2>&1
	code=$?
	tally=$(grep -E 'gates passed' "$log" | tail -1 | sed 's/^ *//')
	fails=$(grep -E '^  \[FAIL\]' "$log" | sed -E 's/^  \[FAIL\] [a-z0-9]+ · //' | sed 's/  {.*//')
	if [ "$code" -eq 0 ]; then
		pass "$group ($tally)"
	elif [ -n "$KNOWN_RED" ] && [ -n "$fails" ] && [ -z "$(printf '%s\n' "$fails" | grep -vE "^($KNOWN_RED)")" ]; then
		pass "$group ($tally; known-red: $(printf '%s' "$fails" | paste -sd';' - | sed 's/;/; /g'))"
	else
		printf '%s\n' "$fails" | sed 's/^/      /'
		fail "$group ($tally)"
	fi
	rm -f "$log"
done

printf '\n— tally —\n'
printf '  %d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ] || exit 1
