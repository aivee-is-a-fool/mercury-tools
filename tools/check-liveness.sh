#!/usr/bin/env bash
# check-liveness.sh — the outside view of run-with-marker.sh. Answers, as a
# separate process: did the guarded thing actually COMPLETE recently?
# Red on four failure shapes:
#   1. marker absent        -> the guarded run never finished (maybe never started)
#   2. marker unreadable    -> someone or something corrupted the record
#   3. marker unparseable   -> the writer's format and this parser disagree
#   4. marker too old       -> it used to run and stopped
#
# A fifth condition, mtime diverging from the record, is REPORTED but is not red;
# see the note below.
#
# Shape 3, and the mtime comparison that used to be shape 4, were added
# 2026-08-26 after @mercury-girl asked whether a DEAD
# was a true negative or a writer/parser format mismatch. It could not have been
# a mismatch: this script never read the marker's CONTENT, only its mtime. That
# is the defect. mtime is metadata any copy, checkout or `touch` refreshes, while
# the completion time the guard actually wrote sat there unread. The authoritative
# record must be the one that is checked.
#
# SHAPE 4 ("touched") IS DEMOTED TO A NOTE, and the reason is a measurement, not
# an opinion. @mercury-girl raised on mercury-hub#2 that `touched` compares mtime
# to the record while git rewrites mtime on every checkout, and proposed telling
# the two causes apart with `git ls-files --error-unmatch`. That would add a git
# dependency to a checker whose whole job is to run on a machine where something
# already failed. It is also unnecessary, because the distinction does not change
# any verdict. Forced all four combinations against this file and against a copy
# with shape 4 disabled:
#
#   record 1h old (inside limit), mtime refreshed by a checkout
#       with shape 4     DEAD: marker touched - differ by 3601s
#       without shape 4  alive: last completion 3601s ago      <- the truth
#
#   record 2 days old, touched to look fresh (the tamper shape 4 exists for)
#       with shape 4     DEAD: marker touched
#       without shape 4  DEAD: last completion 172800s ago (limit 86400s)
#
# Shape 4 has NO true positive that shape 5 does not already catch, and it has at
# least one false positive. Faking mtime cannot fool this checker, because age is
# read from the record; that was the 2026-08-26 fix. So the alarm was guarding a
# door that fix had already locked.
#
# The drift is still worth SAYING - something did write to the file after the run
# did - so it is now appended to the verdict instead of replacing it. An
# instrument that fires on a condition which cannot change the answer is noise,
# and this repo's own rule is that a check which cannot fail meaningfully gets
# sharpened or deleted.
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
DRIFT_NOTE=""
if (( DRIFT > SKEW_TOLERANCE )); then
    DRIFT_NOTE=" [mtime differs from the record by ${DRIFT}s - a checkout, copy or touch rewrote it; the verdict is read from the record, so this does not change it]"
fi

# Age comes from the record the guard wrote, not from the file's metadata.
AGE=$(( NOW - RECORDED ))
LIMIT=$(( MAXAGE_MIN * 60 ))

if (( AGE > LIMIT )); then
    echo "DEAD [$LABEL]: last completion ${AGE}s ago (limit ${LIMIT}s) — $BODY$DRIFT_NOTE"
    exit 1
fi

echo "alive [$LABEL]: last completion ${AGE}s ago — $BODY$DRIFT_NOTE"
exit 0
