#!/bin/zsh
# Pulls the original Vorssaint's latest work into this fork: fetches
# `upstream`, merges upstream/main into the current branch, then builds and
# runs the tests. Nothing is pushed; that stays your call.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -n "$(git status --porcelain)" ]]; then
    echo "✗ You have uncommitted changes. Commit or stash them first."
    exit 1
fi
git remote get-url upstream >/dev/null 2>&1 || git remote add upstream https://github.com/vorssaint/vorssaint-utils.git

branch=$(git branch --show-current)
echo "▸ Fetching upstream…"
git fetch upstream --tags --quiet
behind=$(git rev-list --count "HEAD..upstream/main")
if [[ "$behind" == "0" ]]; then
    echo "✓ Already up to date with upstream."
    exit 0
fi
echo "▸ Merging $behind new upstream commit(s) into $branch…"
if ! git merge --no-edit upstream/main; then
    echo ""
    echo "✗ Merge conflicts. Fix the files listed above, then:"
    echo "    git add <files> && git commit"
    echo "    ./build.sh --dev --test"
    exit 1
fi
echo "▸ Building and testing…"
./build.sh --dev --test
echo ""
echo "✓ Merged and tests pass. To install:  ./build.sh --dev --install"
echo "  To publish:                         git push origin $branch:main"
