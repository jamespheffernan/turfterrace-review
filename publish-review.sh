#!/bin/bash
# Compatibility wrapper. Canonical publish behavior lives in scripts/turf-review.js.

set -euo pipefail

: "${REVIEW_USER:?Set REVIEW_USER before publishing}"
: "${REVIEW_PASSWORD:?Set REVIEW_PASSWORD before publishing}"
TURF_REVIEW_URL="${TURF_REVIEW_URL:-http://localhost:3457}"

FILE=""
TITLE=""
CATEGORY="general"
TASK_ID=""
PROJECT_ID=""
ORIGIN_SESSION_KEY="${TURF_REVIEW_ORIGIN_SESSION_KEY:-}"
BASE_URL="${TURF_REVIEW_BASE_URL:-http://localhost:3457}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task) TASK_ID="$2"; shift 2 ;;
    --project) PROJECT_ID="$2"; shift 2 ;;
    --origin-session) ORIGIN_SESSION_KEY="$2"; shift 2 ;;
    --base-url) BASE_URL="$2"; shift 2 ;;
    --actions) shift 2 ;;
    --ad-hoc) shift ;;
    *)
      if [[ -z "$FILE" ]]; then FILE="$1"
      elif [[ -z "$TITLE" ]]; then TITLE="$1"
      else CATEGORY="$1"
      fi
      shift
      ;;
  esac
done

if [[ -z "$FILE" || -z "$TITLE" ]]; then
  echo "Usage: publish-review.sh <file.md|file.html> \"Title\" [category] [--task ID] [--project ID] [--origin-session KEY]"
  exit 1
fi

ARGS=(publish "$FILE" --title "$TITLE" --category "$CATEGORY" --base-url "$BASE_URL")
[[ -n "$TASK_ID" ]] && ARGS+=(--task "$TASK_ID")
[[ -n "$PROJECT_ID" ]] && ARGS+=(--project "$PROJECT_ID")
[[ -n "$ORIGIN_SESSION_KEY" ]] && ARGS+=(--origin-session "$ORIGIN_SESSION_KEY")

node "$(dirname "$0")/scripts/turf-review.js" "${ARGS[@]}"
