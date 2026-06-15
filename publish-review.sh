#!/bin/bash
# Publish a git-tracked markdown file to Turf Review for Jimmy to review.
# Turf Review derives actions from category and requires workspaceDir/sourcePath.
# Use task-list items or approval/checklist sections for native per-item yes/no.
# Usage: publish-review.sh <file.md> "Title" [category] [--task ID] [--project ID] [--origin-session KEY]

set -e

: "${REVIEW_USER:?Set REVIEW_USER before publishing}"
: "${REVIEW_PASSWORD:?Set REVIEW_PASSWORD before publishing}"
TURF_REVIEW_URL="${TURF_REVIEW_URL:-http://localhost:3457}"

FILE=""
TITLE=""
CATEGORY="general"
TASK_ID=""
PROJECT_ID=""
ACTIONS=""
ORIGIN_SESSION_KEY="${TURF_REVIEW_ORIGIN_SESSION_KEY:-}"
ALLOWED_CATEGORIES=("general" "admin" "outreach" "kitchenlux")

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task) TASK_ID="$2"; shift 2 ;;
    --project) PROJECT_ID="$2"; shift 2 ;;
    --actions) ACTIONS="$2"; shift 2 ;;
    --origin-session) ORIGIN_SESSION_KEY="$2"; shift 2 ;;
    *)
      if [[ -z "$FILE" ]]; then FILE="$1"
      elif [[ -z "$TITLE" ]]; then TITLE="$1"
      else CATEGORY="$1"
      fi
      shift ;;
  esac
done

if [[ -z "$FILE" || -z "$TITLE" ]]; then
  echo "Usage: publish-review.sh <file.md> \"Title\" [category] [--task ID] [--project ID] [--origin-session KEY]"
  exit 1
fi

if [[ ! -f "$FILE" ]]; then
  echo "Error: File not found: $FILE"
  exit 1
fi

if [[ ! " ${ALLOWED_CATEGORIES[*]} " =~ " ${CATEGORY} " ]]; then
  echo "Error: invalid category '$CATEGORY'. Allowed: ${ALLOWED_CATEGORIES[*]}"
  exit 1
fi

if [[ ! -s "$FILE" ]]; then
  echo "Error: file is empty: $FILE"
  exit 1
fi

if ! grep -qE '^#' "$FILE"; then
  echo "Error: markdown file must contain at least one heading"
  exit 1
fi

CONTENT_LENGTH=$(python3 -c "import pathlib,sys; print(len(pathlib.Path(sys.argv[1]).read_text()))" "$FILE")
if [[ "$CONTENT_LENGTH" -lt 10 ]]; then
  echo "Error: markdown file must contain at least 10 characters"
  exit 1
fi

SOURCE_PATH=$(python3 -c "import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve())" "$FILE")
WORKSPACE_DIR=$(git -C "$(dirname "$SOURCE_PATH")" rev-parse --show-toplevel 2>/dev/null || true)

if [[ -z "$WORKSPACE_DIR" ]]; then
  echo "Error: could not determine a git workspace for $SOURCE_PATH"
  exit 1
fi

RELATIVE_SOURCE=$(python3 -c "import os,sys; print(os.path.relpath(sys.argv[2], sys.argv[1]))" "$WORKSPACE_DIR" "$SOURCE_PATH")
if ! git -C "$WORKSPACE_DIR" ls-files --error-unmatch "$RELATIVE_SOURCE" >/dev/null 2>&1; then
  echo "Error: source file must already be git-tracked: $SOURCE_PATH"
  exit 1
fi

if [[ -n "$ACTIONS" ]]; then
  echo "Warning: --actions is ignored. Turf Review now derives actions from category." >&2
fi

MARKDOWN=$(cat "$FILE" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))")
TITLE_JSON=$(echo "$TITLE" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip()))")
WORKSPACE_JSON=$(echo "$WORKSPACE_DIR" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip()))")
SOURCE_JSON=$(echo "$SOURCE_PATH" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip()))")
ORIGIN_SESSION_JSON=$(echo "$ORIGIN_SESSION_KEY" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip()))")

# Build JSON payload
PAYLOAD="{\"title\": $TITLE_JSON, \"markdown\": $MARKDOWN, \"category\": \"$CATEGORY\", \"workspaceDir\": $WORKSPACE_JSON, \"sourcePath\": $SOURCE_JSON"
[[ -n "$TASK_ID" ]] && PAYLOAD="$PAYLOAD, \"taskId\": \"$TASK_ID\""
[[ -n "$PROJECT_ID" ]] && PAYLOAD="$PAYLOAD, \"projectId\": \"$PROJECT_ID\""
[[ -n "$ORIGIN_SESSION_KEY" ]] && PAYLOAD="$PAYLOAD, \"originSessionKey\": $ORIGIN_SESSION_JSON"
PAYLOAD="$PAYLOAD}"

RESPONSE=$(curl -s -X POST "$TURF_REVIEW_URL/api/publish" \
  -u "$REVIEW_USER:$REVIEW_PASSWORD" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD")

SLUG=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('slug','ERROR'))" 2>/dev/null)

if [[ "$SLUG" == "ERROR" || -z "$SLUG" ]]; then
  echo "Error publishing: $RESPONSE"
  exit 1
fi

echo "Published: https://review.turfterrace.com/review/$SLUG"
echo "(Local: http://localhost:3457/review/$SLUG)"
