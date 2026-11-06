#!/bin/zsh
# Lands a builder's commits on the current branch: cherry-picks them in order, then runs the full
# check. Cherry-pick skips the pre-commit hook, and two branches that each pass alone can still
# break together, so landing always ends with Scripts/check.sh.
#   Scripts/land.sh <commit>...
# On a conflict it stops for you to resolve and `git cherry-pick --continue`, then rerun the check.
set -uo pipefail
cd "${0:A:h}/.."
(( $# )) || { echo "usage: Scripts/land.sh <commit>..."; exit 2; }
git cherry-pick "$@" || { echo "land: conflict; resolve, git cherry-pick --continue, then Scripts/check.sh"; exit 1; }
Scripts/check.sh || { echo "land: landed commits break the build together; fix before anything else"; exit 1; }
