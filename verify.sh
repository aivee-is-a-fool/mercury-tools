#!/usr/bin/env bash
# verify.sh — does the vendored copy still match its lock?
#
# Run from the root of the consuming repo:
#   ./verify.sh [vendor-dir]
#
# Exit 0 = the vendored tools are byte-identical to what install.sh recorded.
# Exit 1 = drift: a local edit, a partial install, or a file that went missing.
#
# This is the half that makes vendoring worth anything. Copying a file gives you
# a file; copying a file plus a recorded hash gives you a claim someone else can
# falsify. Same shape as check-liveness.sh: the record that is checked must be
# the record that was written.

set -uo pipefail

DEST="${1:-vendor/mercury-tools}"
LOCK="$DEST/mercury-tools.lock"

[[ -r "$LOCK" ]] || { echo "DRIFT: no lock at $LOCK — nothing was installed, or the lock was not committed"; exit 1; }

RC=0
while read -r HASH FILE; do
    [[ ${#HASH} -eq 64 ]] || continue
    # Two things the lock line can carry that are not part of the filename:
    #   *  sha256sum's binary-mode marker (Git Bash writes it, coreutils does not)
    #   \r a CRLF line ending, which git introduces on checkout under
    #      core.autocrlf unless .gitattributes stops it. Reproduced: every file
    #      then reads as "in the lock and missing from disk".
    FILE="${FILE#\*}"
    FILE="${FILE%$'\r'}"
    if [[ ! -e "$DEST/$FILE" ]]; then
        echo "DRIFT: $FILE is in the lock and missing from $DEST"
        RC=1
        continue
    fi
    ACTUAL=$(sha256sum < "$DEST/$FILE" | cut -d' ' -f1)
    if [[ "$ACTUAL" != "$HASH" ]]; then
        echo "DRIFT: $FILE differs from the lock (locked ${HASH:0:12}, found ${ACTUAL:0:12})"
        RC=1
    fi
done < "$LOCK"

# A file present in the vendor directory but absent from the lock is also drift:
# it is running, and nothing recorded where it came from.
while read -r F; do
    REL="${F#"$DEST"/}"
    grep -qE "[[:space:]][*]?${REL}"$'\r'"?\$" "$LOCK" || { echo "DRIFT: $REL is present but not in the lock"; RC=1; }
done < <(find "$DEST/tools" -type f 2>/dev/null)

if [[ $RC -eq 0 ]]; then
    echo "ok: $DEST matches its lock — $(sed -n 's/^commit //p' "$LOCK" | tr -d '\r' | cut -c1-7), version $(sed -n 's/^version //p' "$LOCK" | tr -d '\r')"
fi
exit $RC
