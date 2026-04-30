#!/usr/bin/env bash
# Post or update a Lighthouse audit comment on a PR.
# Usage: lighthouse-post-comment.sh <body> <repo> <pr_json> <ref_name>
# Env: GH_TOKEN
set -euo pipefail

BODY="${1:?}"
REPO="${2:?}"
PR_JSON="${3:-[]}"
REF_NAME="${4:-}"

# Get PR number from workflow_run context or by branch name
if [[ -n "$PR_JSON" ]] && [[ "$PR_JSON" != "[]" ]]; then
    PR=$(echo "$PR_JSON" |
        python3 -c "import json,sys; print(json.load(sys.stdin)[0]['number'])")
else
    OWNER="${REPO%%/*}"
    PR=$(gh api "repos/${REPO}/pulls?head=${OWNER}:${REF_NAME}&state=open" \
        --jq '.[0].number')
fi
[[ -n "$PR" ]] || {
    echo "⚠ No PR found — skipping comment"
    exit 0
}

MARKER="<!-- lighthouse-audit -->"
FULL_BODY="${MARKER}
${BODY}"

# Find existing comment by marker
COMMENT_ID=$(gh api "repos/${REPO}/issues/${PR}/comments" \
    --jq ".[] | select(.body | startswith(\"${MARKER}\")) | .id" | head -1)

if [[ -n "$COMMENT_ID" ]]; then
    gh api "repos/${REPO}/issues/comments/${COMMENT_ID}" \
        -X PATCH -f body="$FULL_BODY"
    echo "Updated comment $COMMENT_ID on PR #$PR"
else
    gh api "repos/${REPO}/issues/${PR}/comments" \
        -f body="$FULL_BODY"
    echo "Posted new comment on PR #$PR"
fi
