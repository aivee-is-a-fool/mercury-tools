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
timeout "$TIMEOUT" "$@"
CODE=$?
END=$(date +%s)

if [[ $CODE -ne 0 ]]; then
    echo "wake-guard: guarded command failed or hit the ${TIMEOUT}s timeout (exit $CODE); marker NOT written" >&2
    exit "$CODE"
fi

mkdir -p "$(dirname "$MARKER")"
printf 'completed %s duration=%ss cmd="%s"\n' "$(date -Is)" "$((END - START))" "$*" > "$MARKER"
exit 0
