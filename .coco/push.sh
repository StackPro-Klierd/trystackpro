#!/bin/bash
# KLIERD autonomous push wrapper (Coco)
# Validates with Layer 1, commits, pushes, runs health check, auto-rolls back on failure.
#
# Usage: ./.coco/push.sh "commit message"
#
# Environment:
#   - Reads token from ~/Documents/Claude/Projects/Stack Pro Klierd/.coco_token
#   - Operates on the current git repo
#   - Logs to ./.coco/push.log

set -u
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$REPO_ROOT" ]; then
  echo "❌ Not inside a git repo"
  exit 1
fi
cd "$REPO_ROOT"

MSG="${1:-Coco autonomous push}"
TOKEN_FILE="/sessions/youthful-great-allen/mnt/Documents/Claude/Projects/Stack Pro Klierd/.coco_token"
LOG=".coco/push.log"
mkdir -p .coco
echo "[$(date '+%Y-%m-%d %H:%M:%S')] PUSH START: $MSG" >> "$LOG"

# ─── 1. Validate ──────────────────────────────────────────────────
if [ -z "${COCO_BYPASS_VALIDATE:-}" ]; then
  if [ -x ./.coco/validate.sh ]; then
    ./.coco/validate.sh "$REPO_ROOT" || {
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] VALIDATION FAILED — push aborted" >> "$LOG"
      exit 1
    }
  fi
fi

# ─── 2. Check token ───────────────────────────────────────────────
if [ ! -f "$TOKEN_FILE" ]; then
  echo "❌ Token file missing: $TOKEN_FILE"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] TOKEN MISSING" >> "$LOG"
  exit 1
fi
TOKEN=$(tr -d '\n[:space:]' < "$TOKEN_FILE")
ORIGIN=$(git remote get-url origin)
# Strip any embedded credentials (x-access-token:...@) AND trailing slash before re-adding fresh token
HOST_PATH=$(echo "$ORIGIN" | sed -E 's#^https://[^/]*@##; s#^https://##; s#^git@github.com:#github.com/#; s#/$##')
PUSH_URL="https://x-access-token:${TOKEN}@${HOST_PATH}"

# ─── 3. Capture pre-push commit (for rollback) ────────────────────
PREVIOUS_SHA=$(git rev-parse HEAD)
echo "[$(date '+%Y-%m-%d %H:%M:%S')] PREVIOUS HEAD: $PREVIOUS_SHA" >> "$LOG"

# ─── 4. Stage all + commit ────────────────────────────────────────
git add -A
git diff --cached --quiet && {
  echo "ℹ Nothing to commit"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] NO CHANGES" >> "$LOG"
  exit 0
}

git -c user.email="coco@klierd.local" -c user.name="Coco (Cowork)" \
    commit -m "$MSG" 2>&1 | tail -3 || exit 1

NEW_SHA=$(git rev-parse HEAD)
echo "[$(date '+%Y-%m-%d %H:%M:%S')] COMMITTED: $NEW_SHA" >> "$LOG"

# ─── 5. Push ──────────────────────────────────────────────────────
PUSH_OUT=$(git push "$PUSH_URL" main 2>&1)
PUSH_RC=$?
echo "[$(date '+%Y-%m-%d %H:%M:%S')] PUSH RC=$PUSH_RC" >> "$LOG"
echo "$PUSH_OUT" | tail -5

if [ "$PUSH_RC" -ne 0 ]; then
  echo "❌ Push failed — reverting local commit"
  git reset --hard "$PREVIOUS_SHA"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] REVERTED to $PREVIOUS_SHA" >> "$LOG"
  exit 1
fi

echo "✅ Pushed $NEW_SHA → main"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] PUSH COMPLETE: $NEW_SHA" >> "$LOG"

# ─── 6. Wait + health check (Layer 3 light) ───────────────────────
echo "→ Waiting 40s for Vercel deploy..."
sleep 40
if [ -x ./.coco/health_check.sh ]; then
  if ./.coco/health_check.sh; then
    echo "✅ Health check passed"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] HEALTH OK" >> "$LOG"
  else
    echo "❌ Health check FAILED post-deploy"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] HEALTH FAILED — auto-revert" >> "$LOG"
    # Revert the bad commit
    git revert --no-edit "$NEW_SHA" 2>&1 | tail -3
    git push "$PUSH_URL" main 2>&1 | tail -3
    echo "↩ Reverted bad deploy via auto-rollback"
    exit 2
  fi
fi
