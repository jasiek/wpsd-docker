#!/usr/bin/env bash
#
# Fetch one commit of an upstream repository into a fresh checkout.
#
#   fetch-checkout.sh <url> <branch> <ref> <dest>
#
# <ref> may be a branch name or a full commit SHA; <branch> is the local branch
# name to put HEAD on.
#
# Why not `git clone --depth 1 --branch <ref>`: --branch takes a branch or tag,
# never an arbitrary SHA, so it cannot honour a pinned revision. init + fetch does
# both, and both W0CHP Gitea instances allow fetching a SHA directly (verified --
# unlike partial clone, which they do not advertise).
#
# The `checkout -B <branch>` matters: fetching leaves FETCH_HEAD detached, and a
# detached HEAD makes `git symbolic-ref --short HEAD` fail. Four places in WPSD
# run exactly that to render the version it shows its user, and minify-git.sh
# needs the branch name too.
#
set -euo pipefail

URL=${1:?url}
BRANCH=${2:?branch}
REF=${3:?ref}
DEST=${4:?dest}

mkdir -p "$DEST"
git init -q "$DEST"
git -C "$DEST" remote add origin "$URL"
git -C "$DEST" fetch -q --depth 1 origin "$REF"
git -C "$DEST" checkout -q -B "$BRANCH" FETCH_HEAD

echo "fetched $(basename "$URL") ${BRANCH}@$(git -C "$DEST" rev-parse --short=10 HEAD)"
