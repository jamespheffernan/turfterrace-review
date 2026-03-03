#!/bin/bash
# verify-task-deliverable.sh <task-id>
# Reads a Mindwtr task, extracts [deliverable: ...] tag, verifies it exists.
# Exit 0 = pass (verified complete)
# Exit 1 = fail (cannot complete - deliverable missing or not verified)
# Exit 2 = warning (no deliverable tag defined - manual check required)

set -euo pipefail

TASK_ID="${1:-}"
if [ -z "$TASK_ID" ]; then
  echo "Usage: verify-task-deliverable.sh <task-id>"
  exit 1
fi

MW="bun /Users/username/clawd/skills/mindwtr/scripts/mw.ts"

# Get task details
TASK_OUTPUT=$($MW get "$TASK_ID" 2>/dev/null)
if [ $? -ne 0 ] || [ -z "$TASK_OUTPUT" ]; then
  echo "ERROR: Could not find task $TASK_ID"
  exit 1
fi

TITLE=$(echo "$TASK_OUTPUT" | grep "^Title:" | sed 's/^Title:[[:space:]]*//')
DESC=$(echo "$TASK_OUTPUT" | grep "^Description:" | sed 's/^Description:[[:space:]]*//')

# Look for deliverable tag in title or description
DELIVERABLE=""
for TEXT in "$TITLE" "$DESC"; do
  MATCH=$(echo "$TEXT" | grep -oE '\[deliverable: [^]]+\]' 2>/dev/null || true)
  if [ -n "$MATCH" ]; then
    DELIVERABLE=$(echo "$MATCH" | sed 's/\[deliverable: //' | sed 's/\]//')
    break
  fi
done

# CRITICAL: No deliverable tag = cannot verify = FAIL
# This is the exact failure mode we're preventing
if [ -z "$DELIVERABLE" ]; then
  echo "ERROR: No [deliverable: ...] tag found in task title or description"
  echo "Task: $TITLE"
  echo "Cannot verify completion - define the deliverable before marking complete"
  exit 2  # WARNING - manual check required
fi

echo "Verifying deliverable: $DELIVERABLE"

# Parse deliverable type and value
TYPE=$(echo "$DELIVERABLE" | cut -d: -f1)
VALUE=$(echo "$DELIVERABLE" | cut -d: -f2- | sed 's/^[[:space:]]*//')

case "$TYPE" in
  file)
    EXPANDED_PATH=$(eval echo "$VALUE")
    if [ -f "$EXPANDED_PATH" ]; then
      SIZE=$(stat -f %z "$EXPANDED_PATH" 2>/dev/null || echo "?")
      echo "PASS: File exists: $EXPANDED_PATH ($SIZE bytes)"
      exit 0
    else
      echo "FAIL: File does not exist: $EXPANDED_PATH"
      echo "Expected file at: $EXPANDED_PATH"
      exit 1
    fi
    ;;
  url)
    HTTP_CODE=$(curl -sI -o /dev/null -w "%{http_code}" --max-time 30 "$VALUE" 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 400 ]; then
      echo "PASS: URL accessible: $VALUE (HTTP $HTTP_CODE)"
      exit 0
    else
      echo "FAIL: URL not accessible: $VALUE (HTTP $HTTP_CODE)"
      exit 1
    fi
    ;;
  stdout-contains)
    # Value format: "expected string"
    EXPECTED=$(echo "$VALUE" | sed 's/^"//' | sed 's/"$//')
    echo "ERROR: Cannot auto-verify stdout-contains: '$EXPECTED'"
    echo "This requires manual verification - run the command and check output"
    exit 2
    ;;
  approval)
    echo "FAIL: Cannot auto-verify approval from $VALUE"
    echo "Requires explicit confirmation from: $VALUE"
    exit 1
    ;;
  memory)
    # Value format: YYYY-MM-DD.md contains "keyword"
    MEM_FILE=$(echo "$VALUE" | awk '{print $1}')
    KEYWORD=$(echo "$VALUE" | grep -oE '"[^"]+"' | sed 's/"//g')
    MEM_PATH="/Users/username/clawd/memory/$MEM_FILE"
    if [ -f "$MEM_PATH" ] && grep -q "$KEYWORD" "$MEM_PATH" 2>/dev/null; then
      echo "PASS: Memory file $MEM_FILE contains '$KEYWORD'"
      exit 0
    else
      echo "FAIL: Memory file $MEM_FILE missing or doesn't contain '$KEYWORD'"
      [ -f "$MEM_PATH" ] || echo "  File does not exist: $MEM_PATH"
      exit 1
    fi
    ;;
  crm-field)
    # Value format: Field=Value for Airtable record
    # This is complex - need to check Airtable. Currently fail hard.
    echo "ERROR: Cannot auto-verify CRM field update: $VALUE"
    echo "Requires Airtable API check - manual verification needed"
    exit 2
    ;;
  published)
    # Value should be a URL - check it
    if [[ "$VALUE" == http* ]]; then
      HTTP_CODE=$(curl -sI -o /dev/null -w "%{http_code}" --max-time 30 "$VALUE" 2>/dev/null || echo "000")
      if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 400 ]; then
        echo "PASS: Published URL accessible: $VALUE (HTTP $HTTP_CODE)"
        exit 0
      else
        echo "FAIL: Published URL not accessible: $VALUE (HTTP $HTTP_CODE)"
        exit 1
      fi
    else
      echo "ERROR: Published deliverable should be a URL, got: $VALUE"
      exit 2
    fi
    ;;
  none)
    # Explicit "no deliverable" - this is for pure actions (phone calls, meetings)
    # Verify with WARNING - but allow pass
    echo "PASS: No deliverable required (pure action: $TITLE)"
    exit 0
    ;;
  TBD)
    echo "FAIL: Deliverable is TBD - cannot complete task until defined"
    echo "Task: $TITLE"
    exit 1
    ;;
  *)
    echo "ERROR: Unknown deliverable type '$TYPE' - cannot verify"
    echo "Full deliverable: $DELIVERABLE"
    exit 2
    ;;
esac
