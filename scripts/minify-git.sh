#!/usr/bin/env bash
#
# Replace a git checkout's .git directory with metadata only: the branch name and
# the HEAD SHA, and nothing else.
#
# Why this exists, rather than just deleting .git:
#
#   Four places read git metadata to render the version WPSD shows its user --
#   config/version.php, .wpsd-common-funcs and .wpsd-sys-cache (twice) -- via
#   `git symbolic-ref --short HEAD`, `git rev-parse --short=10 <branch>` and
#   `git branch | grep '*'`. Delete .git and the dashboard header reads
#   "WPSD Dashboard Ver.#" with nothing after it, and WPSD_Ver in
#   /etc/WPSD-release goes empty.
#
#   Keeping the full clone means a published image redistributes several thousand
#   commits of someone else's repository history, which upstream explicitly asks
#   people not to do, for 17 MB. This keeps the honest upstream SHA and discards
#   the history.
#
# git recognises a directory as a repository when HEAD resolves and objects/ and
# refs/ exist, so those three plus the origin URL (kept for provenance) are all
# that is needed. No objects, no packs, no reflog.
#
set -euo pipefail

TARGET=${1:?usage: minify-git.sh <checkout-dir>}
GITDIR="$TARGET/.git"

[[ -d $GITDIR ]] || { echo "minify-git: $GITDIR is not a git directory" >&2; exit 1; }

SHA=$(git --git-dir="$GITDIR" rev-parse HEAD)
BRANCH=$(git --git-dir="$GITDIR" symbolic-ref --short HEAD 2>/dev/null || echo master)
ORIGIN=$(git --git-dir="$GITDIR" config --get remote.origin.url 2>/dev/null || echo "")
BEFORE=$(du -sk "$GITDIR" | cut -f1)

rm -rf "$GITDIR"
mkdir -p "$GITDIR/objects" "$GITDIR/refs/heads" "$GITDIR/refs/tags"
printf 'ref: refs/heads/%s\n' "$BRANCH" > "$GITDIR/HEAD"
printf '%s\n' "$SHA"                    > "$GITDIR/refs/heads/$BRANCH"
{
    printf '[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = false\n'
    [[ -n $ORIGIN ]] && printf '[remote "origin"]\n\turl = %s\n' "$ORIGIN"
} > "$GITDIR/config"

AFTER=$(du -sk "$GITDIR" | cut -f1)
echo "minify-git: $TARGET  ${BRANCH}@${SHA:0:10}  ${BEFORE}K -> ${AFTER}K"

# Fail loudly if the commands WPSD actually runs no longer work.
g() { git --work-tree="$TARGET" --git-dir="$GITDIR" "$@"; }
[[ $(g symbolic-ref --short HEAD) == "$BRANCH" ]]        || { echo "minify-git: symbolic-ref broken" >&2; exit 1; }
[[ $(g rev-parse --short=10 "$BRANCH") == "${SHA:0:10}" ]] || { echo "minify-git: rev-parse broken" >&2; exit 1; }
[[ $(g branch | grep '\*' | cut -f2 -d' ') == "$BRANCH" ]] || { echo "minify-git: branch listing broken" >&2; exit 1; }
