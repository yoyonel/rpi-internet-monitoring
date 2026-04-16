#!/usr/bin/env bash
set -euo pipefail

# Post (or update) a PR comment with the preview screenshot.
# Usage: scripts/pr-comment-screenshot.sh <preview_url> <pr_number> <sha>
#
# Requires: GH_TOKEN env var (github.token), gh CLI

URL="${1:?Usage: pr-comment-screenshot.sh <preview_url> <pr_number> <sha>}"
PR="${2:?Missing PR number}"
SHA="${3:?Missing commit SHA}"
SHORT_SHA="${SHA:0:7}"
REPO="${GITHUB_REPOSITORY:?Missing GITHUB_REPOSITORY}"
MARKER="<!-- e2e-preview-screenshot -->"

BODY="${MARKER}
### 📸 Preview — \`${SHORT_SHA}\`

![Preview](${URL}/preview.png)

| | |
|---|---|
| **E2E tests** | ✅ passed |
| **Preview** | ${URL} |
| **Commit** | ${SHORT_SHA} |"

# Find existing comment with our marker (update instead of spam)
COMMENT_ID=$(gh api "repos/${REPO}/issues/${PR}/comments" \
    --jq ".[] | select(.body | contains(\"${MARKER}\")) | .id" |
    head -1)

if [[ -n "$COMMENT_ID" ]]; then
    gh api "repos/${REPO}/issues/comments/${COMMENT_ID}" \
        -X PATCH -f body="${BODY}" >/dev/null
    echo "Updated comment #${COMMENT_ID}"
else
    gh pr comment "${PR}" --body "${BODY}"
    echo "Created new comment"
fi
