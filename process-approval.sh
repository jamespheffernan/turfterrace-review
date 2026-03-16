#!/bin/bash
# process-approval.sh <turf-review-slug>
# Exit 0: success
# Exit 1: error
# Exit 2: no linked task (manual processing required)

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

CURL_BIN="/usr/bin/curl"
PYTHON_BIN="/usr/bin/python3"
BUN_BIN="/opt/homebrew/bin/bun"
OPENCLAW_BIN="/opt/homebrew/bin/openclaw"
MW_SCRIPT="/Users/username/clawd/skills/mindwtr/scripts/mw.ts"
SYNC_SCRIPT="/Users/username/clawd/scripts/sync-mindwtr-to-of.ts"
MW_DB="/Users/username/Library/Application Support/mindwtr/mindwtr.db"
TAIL_BIN="/usr/bin/tail"
SED_BIN="/usr/bin/sed"
TR_BIN="/usr/bin/tr"
CUT_BIN="/usr/bin/cut"
DATE_BIN="/bin/date"

API_BASE_URL="http://localhost:3457"
API_AUTH="jimmy:JWkx5ba0OOGEqVVc"

SLUG="${1:-}"
if [[ -z "$SLUG" ]]; then
  echo "Usage: process-approval.sh <turf-review-slug>"
  exit 1
fi

log() {
  printf '[process-approval] %s\n' "$*"
}

send_manual_required_event() {
  local reason="${1:-Manual task follow-up required}"
  local text="TURF REVIEW MANUAL REQUIRED | slug=\"${ITEM_SLUG:-$SLUG}\" | title=\"${ITEM_TITLE:-unknown}\" | decision=\"${ITEM_DECISION:-unknown}\" | taskId=\"${ITEM_TASK_ID:-none}\" | reason=\"${reason}\""

  "$OPENCLAW_BIN" system event --text "$text" --mode now >/dev/null 2>&1 || true
}

manual_required() {
  local reason="${1:-Manual task follow-up required}"
  log "$reason"
  send_manual_required_event "$reason"
  exit 2
}

HTTP_RESPONSE=$("$CURL_BIN" -sS -u "$API_AUTH" \
  -H "Accept: application/json" \
  "$API_BASE_URL/api/items/$SLUG" \
  -w $'\n%{http_code}')

HTTP_CODE=$(printf '%s' "$HTTP_RESPONSE" | "$TAIL_BIN" -n 1)
RESPONSE_BODY=$(printf '%s' "$HTTP_RESPONSE" | "$SED_BIN" '$d')
if [[ "$HTTP_CODE" -ge 400 ]]; then
  echo "Error: failed to fetch review item '$SLUG' (HTTP $HTTP_CODE): $RESPONSE_BODY"
  exit 1
fi

ITEM_FIELDS=$("$PYTHON_BIN" - "$RESPONSE_BODY" <<'PY'
import json
import sys

def clean(v):
    return (v or "").replace("\n", " ").replace("\r", " ").strip()

try:
    item = json.loads(sys.argv[1])
except Exception:
    print("")
    sys.exit(1)

vals = [
    clean(item.get("slug")),
    clean(item.get("title")),
    clean(item.get("decision")),
    clean(item.get("feedback")),
    clean(item.get("mindwtr_task_id")),
    clean(item.get("mindwtr_project_id")),
]
print("\x1f".join(vals))
PY
)

if [[ -z "$ITEM_FIELDS" ]]; then
  echo "Error: could not parse API response for slug '$SLUG'"
  exit 1
fi

IFS=$'\x1f' read -r ITEM_SLUG ITEM_TITLE ITEM_DECISION ITEM_FEEDBACK ITEM_TASK_ID ITEM_PROJECT_ID <<< "$ITEM_FIELDS"

if [[ -z "$ITEM_DECISION" ]]; then
  echo "Error: review item '$SLUG' has no decision yet"
  exit 1
fi

if [[ -z "$ITEM_TASK_ID" ]]; then
  manual_required "No linked Mindwtr task for '$SLUG'. Manual processing required."
fi

set +e
TASK_META=$("$PYTHON_BIN" - "$MW_DB" "$ITEM_TASK_ID" <<'PY'
import sqlite3
import sys

db_path = sys.argv[1]
task_prefix = sys.argv[2]

con = sqlite3.connect(db_path)
row = con.execute(
    "SELECT id, title, COALESCE(projectId, '') FROM tasks WHERE deletedAt IS NULL AND id LIKE ? ORDER BY updatedAt DESC LIMIT 1",
    (task_prefix + "%",),
).fetchone()
con.close()

if not row:
    sys.exit(2)

print("\t".join([row[0], row[1], row[2]]))
PY
)
TASK_META_EXIT=$?
set -e

if [[ $TASK_META_EXIT -eq 2 || -z "$TASK_META" ]]; then
  manual_required "Linked Mindwtr task '$ITEM_TASK_ID' could not be resolved automatically for '$SLUG'."
elif [[ $TASK_META_EXIT -ne 0 ]]; then
  log "Failed to resolve linked Mindwtr task '$ITEM_TASK_ID' (exit $TASK_META_EXIT)."
  exit 1
fi

TASK_FULL_ID=$(printf '%s' "$TASK_META" | "$CUT_BIN" -f1)
TASK_TITLE=$(printf '%s' "$TASK_META" | "$CUT_BIN" -f2)
TASK_PROJECT_ID=$(printf '%s' "$TASK_META" | "$CUT_BIN" -f3)

DECISION_NORMALIZED=$(printf '%s' "$ITEM_DECISION" | "$TR_BIN" '[:upper:]' '[:lower:]')

OUTCOME=""
if [[ "$DECISION_NORMALIZED" == approve* ]]; then
  OUTCOME="approved"
elif [[ "$DECISION_NORMALIZED" == reject* ]]; then
  OUTCOME="rejected"
else
  echo "Error: unsupported decision '$ITEM_DECISION'. Expected an approve/reject decision."
  exit 1
fi

if [[ "$OUTCOME" == "approved" ]]; then
  if "$BUN_BIN" "$MW_SCRIPT" complete "$TASK_FULL_ID" >/dev/null 2>&1; then
    log "Marked task done: $TASK_FULL_ID ($TASK_TITLE)"
  else
    log "Failed to complete task '$TASK_FULL_ID' for slug '$SLUG'."
    exit 1
  fi
else
  NOTE_TS=$("$DATE_BIN" -u +"%Y-%m-%dT%H:%M:%SZ")
  NOTE="[Turf Review rejected $NOTE_TS] $ITEM_TITLE ($ITEM_SLUG)"
  if [[ -n "$ITEM_FEEDBACK" ]]; then
    NOTE="$NOTE | Feedback: $ITEM_FEEDBACK"
  fi

  "$PYTHON_BIN" - "$MW_DB" "$TASK_FULL_ID" "$NOTE" <<'PY'
import datetime
import sqlite3
import sys

db_path = sys.argv[1]
task_id = sys.argv[2]
note = sys.argv[3]

con = sqlite3.connect(db_path)
row = con.execute(
    "SELECT COALESCE(description, '') FROM tasks WHERE id = ? AND deletedAt IS NULL",
    (task_id,),
).fetchone()
if not row:
    con.close()
    sys.exit(2)

description = row[0]
if description.strip():
    description = f"{description}\n\n{note}"
else:
    description = note

now = datetime.datetime.utcnow().replace(microsecond=0).isoformat() + "Z"
con.execute(
    "UPDATE tasks SET status = 'next', completedAt = NULL, description = ?, updatedAt = ?, rev = COALESCE(rev, 0) + 1, revBy = 'process-approval.sh' WHERE id = ?",
    (description, now, task_id),
)
con.commit()
con.close()
PY
  log "Moved task back to next with rejection note: $TASK_FULL_ID ($TASK_TITLE)"
fi

SUCCESSOR_PROJECT_ID="$ITEM_PROJECT_ID"
if [[ -z "$SUCCESSOR_PROJECT_ID" ]]; then
  SUCCESSOR_PROJECT_ID="$TASK_PROJECT_ID"
fi

PROJECT_TITLE=""
if [[ -n "$SUCCESSOR_PROJECT_ID" ]]; then
  PROJECT_TITLE=$("$PYTHON_BIN" - "$MW_DB" "$SUCCESSOR_PROJECT_ID" <<'PY'
import sqlite3
import sys

con = sqlite3.connect(sys.argv[1])
row = con.execute(
    "SELECT title FROM projects WHERE id = ? AND deletedAt IS NULL LIMIT 1",
    (sys.argv[2],),
).fetchone()
con.close()
print(row[0] if row else "")
PY
)
fi

if [[ "$OUTCOME" == "approved" ]]; then
  DEFAULT_SUCCESSOR_TITLE="Next step after approval: $ITEM_TITLE"
else
  DEFAULT_SUCCESSOR_TITLE="Revise and resubmit: $ITEM_TITLE"
fi

SUCCESSOR_TITLE="$DEFAULT_SUCCESSOR_TITLE"
if [[ -t 0 && -t 1 ]]; then
  echo "Successor task title [$DEFAULT_SUCCESSOR_TITLE]:"
  read -r USER_SUCCESSOR_TITLE || true
  if [[ -n "${USER_SUCCESSOR_TITLE:-}" ]]; then
    SUCCESSOR_TITLE="$USER_SUCCESSOR_TITLE"
  fi
fi

if [[ -n "$PROJECT_TITLE" ]]; then
  if "$BUN_BIN" "$MW_SCRIPT" add "$SUCCESSOR_TITLE" --project "$PROJECT_TITLE" --status next >/dev/null 2>&1; then
    log "Created successor task in project '$PROJECT_TITLE': $SUCCESSOR_TITLE"
  else
    log "Failed to create successor task '$SUCCESSOR_TITLE' in project '$PROJECT_TITLE'."
    exit 1
  fi
else
  if "$BUN_BIN" "$MW_SCRIPT" add "$SUCCESSOR_TITLE" --status next >/dev/null 2>&1; then
    log "Created successor task: $SUCCESSOR_TITLE"
  else
    log "Failed to create successor task '$SUCCESSOR_TITLE'."
    exit 1
  fi
fi

if "$BUN_BIN" "$SYNC_SCRIPT" >/dev/null 2>&1; then
  log "OmniFocus sync complete."
else
  log "OmniFocus sync failed for slug '$ITEM_SLUG'."
  exit 1
fi

log "process-approval.sh completed for slug: $ITEM_SLUG"
exit 0
