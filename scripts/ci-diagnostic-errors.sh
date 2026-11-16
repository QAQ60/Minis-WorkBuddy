#!/bin/sh
# Print a build log's REAL compiler diagnostics — the lines a person can act on
# — with context around the first one.
#
# Why this exists: the build step used to run
#
#     grep -B2 -A4 -E "error:" build/xcodebuild.log | head -120
#
# which matches "error:" ANYWHERE on a line. A doc comment —
# `/// Build an error envelope: {ok:false, …}` — satisfies that pattern, and
# there are dozens of them in this tree. Those hits filled the 120-line budget
# and the actual compile error never reached the log, so a failed build showed
# nothing but nullability warnings from an unrelated header.
#
# A diagnostic is `path:line:col: error: message`. Requiring the column and the
# severity word is what excludes prose that merely mentions the word.
#
# Usage: scripts/ci-diagnostic-errors.sh <xcodebuild.log>
# Exit status is 0 when diagnostics were printed, 1 when none matched (the
# caller treats that as "fall back to the raw log").

set -u

LOG="${1:-build/xcodebuild.log}"
if [ ! -f "$LOG" ]; then
    echo "--- no build log at $LOG ---"
    exit 1
fi

# GitHub prefixes every line with an ISO timestamp when the log is downloaded
# through the API, so anchor on the FILE rather than on the line start.
DIAG='[^ ]+\.(swift|m|mm|h|c|cc|cpp):[0-9]+:[0-9]+: (error|warning):'

ERRORS=$(grep -E "$DIAG" "$LOG" | grep -F ': error: ' || true)

if [ -z "$ERRORS" ]; then
    # No file:line:col error. Xcode still says why, in one of these shapes.
    echo "--- no file:line:col diagnostics; Xcode's own summary follows ---"
    grep -E '\*\* BUILD FAILED \*\*|The following build commands failed' -A10 "$LOG" \
        | head -60 || true
    echo "--- raw tail ---"
    tail -80 "$LOG"
    exit 1
fi

COUNT=$(printf '%s\n' "$ERRORS" | wc -l | tr -d ' ')
echo "--- $COUNT compile error(s) ---"
printf '%s\n' "$ERRORS" | head -40

echo
echo "--- context of the first error ---"
FIRST=$(printf '%s\n' "$ERRORS" | head -1)
grep -F -B4 -A14 "$FIRST" "$LOG" | head -70

exit 0
