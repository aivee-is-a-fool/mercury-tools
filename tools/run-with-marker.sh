#!/usr/bin/env bash
# run-with-marker.sh — wrap a command so that COMPLETING it is observable
# from outside the process. A gate that crashes at load time emits no output,
# and a harness that reads no output as success cannot tell "ran clean" from
# "never ran".
#
# Usage:
#   run-with-marker.sh <marker-file> [--timeout SEC] -- <command...>
#
# Behavior:
#   - deletes any previous marker first, so a stale green can't survive
#   - runs the command under `timeout`
#   - writes the marker ONLY if the command exited 0 before the deadline
#   - propagates the command's exit code either way
#
# Pair with check-liveness.sh, which reads the marker from OUTSIDE this
# process (cron, operator, next wake) and goes red when it is missing,
# stale, or corrupt. The two halves are deliberately separate processes:
# the whole point is that no check running inside the guarded command can
# certify its own launch.

set -u

usage() { echo "usage: $0 <marker-file> [--timeout SEC] -- <command...>" >&2; exit 64; }

MARKER="${1:-}"; [[ -n "$MARKER" ]] || usage
shift

TIMEOUT=600
if [[ "${1:-}" == "--timeout" ]]; then
    TIMEOUT="${2:-}"; [[ -n "$TIMEOUT" ]] || usage
    shift 2
fi

[[ "${1:-}" == "--" ]] && shift
[[ $# -gt 0 ]] || usage

rm -f "$MARKER"

START=$(date +%s)

# The command records its own exit status to a file from inside the timeout, so
# whether `timeout` was the killer is READ rather than inferred. Exit 124 alone
# cannot tell the two apart: a command may exit 124 of its own accord, and a
# message that names a timeout which did not happen is the same defect as one
# that warns about a timeout that was never near. If the file is empty the inner
# shell never reached its last line, which only happens when it was killed.
# (mercury-boy raised the wording in mercury-tools#4 and named this caveat
# himself; this is the fix he pointed at rather than the one he proposed.)
STATUS_FILE=$(mktemp)
trap 'rm -f "$STATUS_FILE"' EXIT
timeout "$TIMEOUT" bash -c 'f=$1; shift; "$@"; echo $? > "$f"' _ "$STATUS_FILE" "$@"
OUTER=$?
END=$(date +%s)

if [[ -s "$STATUS_FILE" ]]; then
    CODE=$(<"$STATUS_FILE"); KILLED=no
else
    CODE=$OUTER; KILLED=yes
fi

if [[ $CODE -ne 0 || $KILLED == yes ]]; then
    if [[ $KILLED == yes ]]; then
        echo "wake-guard: guarded command hit the ${TIMEOUT}s timeout after $((END - START))s; marker NOT written" >&2
    else
        echo "wake-guard: guarded command failed (exit $CODE) after $((END - START))s; marker NOT written" >&2
    fi
    exit "$CODE"
fi

mkdir -p "$(dirname "$MARKER")"
printf 'completed %s duration=%ss cmd="%s"\n' "$(date -Is)" "$((END - START))" "$*" > "$MARKER"
exit 0
