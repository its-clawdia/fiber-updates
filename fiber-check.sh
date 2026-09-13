#!/usr/bin/env bash
# fiber-check.sh — Daily check for new Mountain View fiber/broadband matters
# Cron: 0 9 * * *
#
# What it does:
#   1. Queries Legistar API for matters modified since last run
#   2. Filters titles against the watched keyword list (fiber-state.json)
#   3. Generates an HTML blog post for any matches and pushes to GitHub Pages
#
# Independent from rengstorff-check.sh — separate repo, separate state.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$SCRIPT_DIR"
STATE_FILE="$SCRIPT_DIR/fiber-state.json"
LEGISTAR_API="https://webapi.legistar.com/v1/mountainview"
TODAY=$(date -u +%Y-%m-%d)
LOG_PREFIX="[fiber-check $(date -u +%H:%M:%S)]"

log() { echo "$LOG_PREFIX $*"; }

# ── 1. Load state ────────────────────────────────────────────────────────────
if [[ -f "$STATE_FILE" ]]; then
  LAST_CHECK=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['last_check'])")
else
  LAST_CHECK=$(date -u -d "30 days ago" +%Y-%m-%dT%H:%M:%S 2>/dev/null \
    || date -u -v-30d +%Y-%m-%dT%H:%M:%S)
fi
log "Last check: $LAST_CHECK"

# ── 2. Sanity check: verify API is reachable ─────────────────────────────────
API_TEST=$(curl -sf --max-time 10 "${LEGISTAR_API}/matters?%24top=1" | python3 -c "import json,sys; d=json.load(sys.stdin); print('ok' if d else 'empty')" 2>/dev/null || echo "FAIL")
if [[ "$API_TEST" == "FAIL" ]]; then
  log "ERROR: Legistar API unreachable. Aborting."
  exit 1
fi
log "API sanity check: $API_TEST"

# ── 3. Sanity check: verify git repo is clean and remote is reachable ────────
cd "$REPO_DIR"
if ! git fetch origin --dry-run 2>/dev/null; then
  log "ERROR: Cannot reach GitHub remote. Aborting."
  exit 1
fi
log "Git remote: reachable"

# ── 4. Fetch recently modified matters, filter by keyword list ───────────────
log "Querying Legistar for matters modified since $LAST_CHECK ..."
RAW=$(curl -sf --max-time 20 \
  "${LEGISTAR_API}/matters?\$filter=MatterLastModifiedUtc+gt+datetime'${LAST_CHECK}'&\$top=200" \
  || echo "[]")

NEW_MATTERS=$(echo "$RAW" | python3 -c "
import json, sys
raw = json.load(sys.stdin)
state = json.load(open('$STATE_FILE'))
keywords = [k.lower() for k in state.get('keywords', [])]
keep = []
for m in raw:
    t = (m.get('MatterTitle') or '').lower()
    if any(k in t for k in keywords):
        keep.append(m)
print(json.dumps(keep))
")

COUNT=$(echo "$NEW_MATTERS" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
log "Found $COUNT new/updated fiber/broadband matter(s)."

if [[ "$COUNT" -eq 0 ]]; then
  log "Nothing to post. Updating state."
  python3 -c "
import json
s = json.load(open('$STATE_FILE'))
s['last_check'] = '$(date -u +%Y-%m-%dT%H:%M:%S)'
json.dump(s, open('$STATE_FILE','w'), indent=2)
"
  git add -A
  if ! git diff --cached --quiet; then
    git commit -m "chore: monitor check - no updates ($TODAY)"
    git push origin main
    log "Pushed state update."
  fi
  exit 0
fi

# ── 5. Generate blog post HTML ────────────────────────────────────────────────
POST_SLUG="${TODAY}-update"
POST_FILE="$REPO_DIR/posts/${POST_SLUG}.html"

python3 - "$NEW_MATTERS" "$TODAY" "$POST_FILE" <<'PYEOF'
import json, sys

matters = json.loads(sys.argv[1])
today = sys.argv[2]
post_file = sys.argv[3]
rows = ""
for m in sorted(matters, key=lambda x: x.get('MatterLastModifiedUtc','') or ''):
    title = (m.get('MatterTitle') or '').replace('<','&lt;').replace('>','&gt;')
    mtype = m.get('MatterTypeName','')
    status = m.get('MatterStatusName','')
    file_no = m.get('MatterFile','')
    modified = (m.get('MatterLastModifiedUtc') or '').split('T')[0]

    rows += f"""
    <li>
      <div class="date">{modified}</div>
      <div><strong>{title}</strong></div>
      <div class="body">Type: {mtype} &nbsp;|&nbsp; Status: {status} &nbsp;|&nbsp; Legistar #{file_no}</div>
    </li>"""

html = f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Mountain View Fiber &amp; Broadband Update — {today}</title>
  <style>
    body {{ font-family: Georgia, serif; max-width: 800px; margin: 40px auto; padding: 0 20px; color: #222; }}
    h1 {{ font-size: 1.8em; border-bottom: 2px solid #333; padding-bottom: 10px; }}
    .meta {{ color: #666; font-size: 0.9em; margin-bottom: 2em; }}
    .timeline {{ list-style: none; padding: 0; }}
    .timeline li {{ margin: 1.8em 0; padding-left: 1.5em; border-left: 3px solid #444; }}
    .timeline .date {{ font-weight: bold; color: #333; }}
    .timeline .body {{ color: #888; font-size: 0.82em; margin-top: 0.3em; }}
    a {{ color: #1a0dab; }}
    nav {{ margin-bottom: 2em; }}
    footer {{ margin-top: 3em; border-top: 1px solid #ccc; padding-top: 1em; color: #666; font-size: 0.85em; }}
  </style>
</head>
<body>
  <nav><a href="../index.html">&larr; All posts</a></nav>
  <h1>Mountain View Fiber &amp; Broadband Update — {today}</h1>
  <div class="meta">Auto-generated: {today} &nbsp;|&nbsp; Source: Mountain View Legistar API</div>
  <p>{len(matters)} new or updated matter(s) detected since last check:</p>
  <ul class="timeline">{rows}
  </ul>
  <footer>
    Data from <a href="https://webapi.legistar.com/v1/mountainview/">Mountain View Legistar API</a>.
  </footer>
</body>
</html>"""

with open(post_file, "w") as f:
    f.write(html)
print(f"Post written: {post_file}")
PYEOF

# ── 6. Update index.html ───────────────────────────────────────────────────────
python3 -c "
index = '$REPO_DIR/index.html'
with open(index) as f: content = f.read()
entry = '''    <li>
      <span class=\"date\">$TODAY</span><br>
      <a href=\"posts/${POST_SLUG}.html\">Fiber/Broadband Update &mdash; $TODAY</a>
    </li>
    '''
content = content.replace('<ul class=\"post-list\">\n', '<ul class=\"post-list\">\n' + entry, 1)
with open(index, 'w') as f: f.write(content)
print('Index updated.')
"

# ── 7. Update state ────────────────────────────────────────────────────────────
python3 -c "
import json
s = json.load(open('$STATE_FILE'))
s['last_check'] = '$(date -u +%Y-%m-%dT%H:%M:%S)'
json.dump(s, open('$STATE_FILE','w'), indent=2)
"

# ── 8. Commit and push ────────────────────────────────────────────────────────
cd "$REPO_DIR"
git add -A
git commit -m "Auto-update: ${COUNT} new fiber/broadband matter(s) — ${TODAY}"
git push origin main
log "Pushed to GitHub."
log "Done."
