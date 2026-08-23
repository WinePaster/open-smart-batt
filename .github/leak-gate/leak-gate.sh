#!/usr/bin/env bash
#
# leak-gate runner -- clean-room leak gate for the PUBLIC repo.
# See ../workflows/leak-gate.yml for what this gate does, what it CANNOT do,
# and the rules for maintaining the pattern files.
#
# Run it locally exactly the way CI runs it:
#
#     bash .github/leak-gate/leak-gate.sh
#
# Exit 0 = no hit. Exit 1 = a red line was hit. Exit 2 = the gate itself is
# misconfigured (a broken gate must never look like a passing gate).

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

GATE_DIR=".github/leak-gate"
PATHS_FILE="$GATE_DIR/forbidden-paths.txt"
CONTENT_FILE="$GATE_DIR/forbidden-content.txt"

# ---------------------------------------------------------------------------
# The self-scan problem, and how it is solved here.
#
# The gate has to write down the strings it hunts for, so a naive content scan
# always matches the gate's own source and stays red forever. Two ways to dodge
# that are tempting and both are wrong: obfuscating the patterns (unreadable,
# and the next person cannot verify them), or excluding a broad glob such as
# `.github/**` (which would let a real leak hide in any workflow file).
#
# What we do instead: the patterns live in two plain data files, and the
# content scan excludes an explicitly enumerated, three-file list -- the gate
# itself and nothing else. Then, because "excluded" means "unwatched", the
# check below refuses to run at all if anything unexpected appears inside
# $GATE_DIR. So the gate's blind spot is exactly three files whose entire
# content is patterns and comments, and any change to them shows up in review.
# ---------------------------------------------------------------------------
GATE_FILES_EXPECTED="$GATE_DIR/forbidden-content.txt
$GATE_DIR/forbidden-paths.txt
$GATE_DIR/leak-gate.sh"

GATE_EXCLUDE_PATHSPECS=(
  ":(exclude)$GATE_DIR/"
  ":(exclude).github/workflows/leak-gate.yml"
)

TMPDIR_GATE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_GATE"' EXIT

# Strip comments and blank lines. A blank line handed to `grep -f` matches
# EVERY line, which would turn the gate into permanent noise; an empty result
# would silently match nothing. Both are configuration errors, not results.
strip_patterns() {
  local src="$1" dst="$2"
  grep -vE '^[[:space:]]*(#.*)?$' "$src" > "$dst" || true
  if [ ! -s "$dst" ]; then
    echo "leak-gate: FATAL: no usable patterns in $src" >&2
    exit 2
  fi
}

fail_banner() {
  echo ""
  echo "=============================================================="
  echo " LEAK GATE FAILED -- clean-room red line"
  echo "=============================================================="
}

# --- 0. Sanity: the gate's own files must be exactly what we exclude --------
for f in "$PATHS_FILE" "$CONTENT_FILE"; do
  [ -f "$f" ] || { echo "leak-gate: FATAL: missing pattern file $f" >&2; exit 2; }
done

GATE_FILES_ACTUAL="$(git ls-files "$GATE_DIR" | LC_ALL=C sort)"
if [ "$GATE_FILES_ACTUAL" != "$(printf '%s' "$GATE_FILES_EXPECTED" | LC_ALL=C sort)" ]; then
  fail_banner
  echo ""
  echo "  $GATE_DIR is excluded from the content scan, so it is the one"
  echo "  place in this repo the gate cannot see. Its contents are therefore"
  echo "  pinned to a fixed list, and that list no longer matches."
  echo ""
  echo "  expected:"
  printf '%s\n' "$GATE_FILES_EXPECTED" | LC_ALL=C sort | sed 's/^/    /'
  echo "  actual:"
  printf '%s\n' "$GATE_FILES_ACTUAL" | sed 's/^/    /'
  echo ""
  echo "  What to do: do not park files in $GATE_DIR. If the gate genuinely"
  echo "  needs another file, add it to GATE_FILES_EXPECTED in this script in"
  echo "  the same commit, so the unwatched surface stays visible in review."
  echo ""
  exit 2
fi

# --- 1. Path check ---------------------------------------------------------
# No exclusions here: none of the gate's own paths resemble a red line, and a
# path check with holes in it is not a path check.
strip_patterns "$PATHS_FILE" "$TMPDIR_GATE/paths"
# No -n: a line number into `git ls-files` output is meaningless noise.
PATH_HITS="$(git ls-files | grep -iE -f "$TMPDIR_GATE/paths" || true)"

# --- 2. Content check ------------------------------------------------------
# -i: the manual pattern said `ibattpro` while the real artifact is
#     `ibattPRO0225.apk`; case-sensitive matching would have missed it.
# No -I: binary files are scanned too. A renamed vendor blob loses the
#     extension the path check keys on, but usually keeps its strings.
strip_patterns "$CONTENT_FILE" "$TMPDIR_GATE/content"
CONTENT_HITS="$(git grep -nEi -f "$TMPDIR_GATE/content" \
                  -- . "${GATE_EXCLUDE_PATHSPECS[@]}" || true)"

# --- 3. Report -------------------------------------------------------------
if [ -z "$PATH_HITS" ] && [ -z "$CONTENT_HITS" ]; then
  echo "leak-gate: OK -- 0 path hits, 0 content hits."
  echo "leak-gate: reminder -- green means no pattern matched. It does NOT"
  echo "leak-gate: mean nothing leaked. See the header of leak-gate.yml."
  exit 0
fi

fail_banner
echo ""
echo "This repository is the PUBLIC, clean-room half of the project. It must"
echo "never carry reverse-engineering working data, vendor binaries, or the"
echo "internal-only documents that live in the pro repo. Publishing any of"
echo "those breaks the clean-room separation that the project's legal"
echo "position rests on -- and git history keeps it forever, so this has to"
echo "be caught before the commit lands, not after."
echo ""

if [ -n "$PATH_HITS" ]; then
  echo "--- Forbidden PATHS (tracked files matching $PATHS_FILE) ---"
  echo "$PATH_HITS" | sed 's/^/  /'
  echo ""
fi

if [ -n "$CONTENT_HITS" ]; then
  echo "--- Forbidden CONTENT (file:line matching $CONTENT_FILE) ---"
  echo "$CONTENT_HITS" | sed 's/^/  /'
  echo ""
fi

cat <<'EOF'
What to do now
--------------
  1. Work out which listed item it is:

     (a) It really is internal material.
         Remove it from this repo and put it in the pro repo instead. If it
         has already been committed here, say so in the PR -- rewriting or
         purging history is an owner decision, not a follow-up commit.

     (b) It is legitimate public content that happens to hit a pattern.
         Then either the wording of that content should change, or the
         pattern should be made more precise. BOTH of those are owner
         rulings. Stop here and ask.

  2. Do NOT relax, narrow, or delete a pattern to make this build go green.
     Widening the hole is precisely the failure this gate exists to prevent,
     and it has happened before: the earlier hand-run pattern hard-coded
     `design/000[1-5]`, so every design doc from 0006 onward walked straight
     past it.

  3. Reproduce locally with:  bash .github/leak-gate/leak-gate.sh
EOF

exit 1
