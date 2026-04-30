#!/usr/bin/env bash
# Push Lighthouse badge JSON files to the gh-pages branch.
# Usage: lighthouse-push-badges.sh <badges_dir> <repo_url>
set -euo pipefail

BADGES_DIR="${1:?Usage: lighthouse-push-badges.sh <badges_dir> <repo_url>}"
REPO_URL="${2:?}"

cd /tmp
git clone --depth 1 --branch gh-pages "$REPO_URL" gh-pages-badges
cd gh-pages-badges
mkdir -p badges
cp "$BADGES_DIR"/*.json badges/
git config user.email "gh-pages-bot@users.noreply.github.com"
git config user.name "GitHub Pages Bot"
git add badges/
if git diff --cached --quiet; then
    echo "No badge changes"
else
    git commit -m "chore: update Lighthouse badges — $(date -Iseconds)"
    git pull --rebase origin gh-pages
    git push origin gh-pages
fi
