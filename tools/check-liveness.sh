#!/usr/bin/env bash
# check-liveness.sh — the outside view of run-with-marker.sh. Answers, as a
# separate process: did the guarded thing actually COMPLETE recently?
# Red on all five failure shapes:
#   1. marker absent        -> the guarded run never finished (maybe never started)
#   2. marker unreadable    -> someone or something corrupted the record
#   3. marker unparseable   -> the writer's format and this parser disagree
#   4. marker touched       -> mtime and the recorded completion time diverge
#   5. marker too old       -> it used to run and stopped
#
# Shapes 3 and 4 were added 2026-08-26 after @mercury-girl asked whether a DEAD
# was a true negative or a writer/parser format mismatch. It could not have been
# a mismatch: this script never read the marker's CONTENT, only its mtime. That
# is the defect. mtime is metadata any copy, checkout or `touch` refreshes, while
# the completion time the guard actually wrote sat there unread. The authoritative
# record must be the one that is checked.
#
# Usage:
#   check-liveness.sh <marker-file> <max-age-minutes> [label]
#
# Exit 0 = alive, exit 1 = dead. One human-readable line either way, so it
# works as a cron mail body or an eyeball check.

set -u

usage() { echo "usage: $0 <marker-file> <max-age-minutes> [label]" >&2; exit 64; }

MARKER="${1:-}"; [[ -n "$MARKER" ]] || usage
MAXAGE_MIN="${2:-}"; [[ -n "$MAXAGE_MIN" ]] || usage
LABEL="${3:-$(basename "$MARKER")}"

# How far mtime may drift from the recorded completion time before the marker is
# treated as touched rather than written. Generous: filesystem timestamp
# granularity and a slow write are not evidence of tampering.
SKEW_TOLERANCE=120

if [[ ! -e "$MARKER" ]]; then
    echo "DEAD [$LABEL]: marker absent — guarded run did not complete"
    exit 1
fi

if [[ ! -r "$MARKER" ]]; then
    echo "DEAD [$LABEL]: marker unreadable — record exists but cannot be checked"
    exit 1
fi

BODY=$(head -n1 "$MARKER")

# The guard writes: completed <ISO-8601> duration=<n>s cmd="<...>"
STAMP=$(printf '%s' "$BODY" | sed -n 's/^completed \([0-9T:+-]\{19,25\}\).*/\1/p')
if [[ -z "$STAMP" ]]; then
    echo "DEAD [$LABEL]: marker unparseable — no 'completed <ISO>' field in \"$BODY\""
    exit 1
fi

RECORDED=$(date -d "$STAMP" +%s 2>/dev/null) || RECORDED=""
if [[ -z "$RECORDED" ]]; then
    echo "DEAD [$LABEL]: marker timestamp \"$STAMP\" is not a date this checker can read"
    exit 1
fi

NOW=$(date +%s)
MTIME=$(stat -c %Y "$MARKER" 2>/dev/null) || { echo "DEAD [$LABEL]: marker stat failed"; exit 1; }

DRIFT=$(( MTIME - RECORDED )); (( DRIFT < 0 )) && DRIFT=$(( -DRIFT ))
if (( DRIFT > SKEW_TOLERANCE )); then
    echo "DEAD [$LABEL]: marker touched — file mtime and recorded completion differ by ${DRIFT}s; the record was not written by the run that owns this file"
    exit 1
fi

# Age comes from the record the guard wrote, not from the file's metadata.
AGE=$(( NOW - RECORDED ))
LIMIT=$(( MAXAGE_MIN * 60 ))

if (( AGE > LIMIT )); then
    echo "DEAD [$LABEL]: last completion ${AGE}s ago (limit ${LIMIT}s) — $BODY"
    exit 1
fi

echo "alive [$LABEL]: last completion ${AGE}s ago — $BODY"
exit 0
