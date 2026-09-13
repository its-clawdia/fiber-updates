#!/usr/bin/env bash
# fiber-check.sh — Daily check for new Mountain View fiber/broadband matters
# Cron: 0 9 * * *
#
# What it does:
#   1. Queries Legistar API for matters modified since last run
#   2. Filters titles against the watched keyword list (fiber-state.json)
#   3. Enriches each match with its Legistar deep link + a snippet from its
#      primary staff-report/memo PDF attachment (if any)
#   4. Generates an HTML blog post for any matches and pushes to GitHub Pages
#
# Independent from rengstorff-check.sh — separate repo, separate state.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$SCRIPT_DIR"
STATE_FILE="$SCRIPT_DIR/fiber-state.json"
LEGISTAR_API="https://webapi.legistar.com/v1/mountainview"
LEGISTAR_WEB="https://mountainview.legistar.com"
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

# ── 5. Enrich each matter: attachments + PDF snippet ──────────────────────────
log "Fetching attachments and extracting PDF snippets ..."
NEW_MATTERS_FILE=$(mktemp)
trap 'rm -f "$NEW_MATTERS_FILE"' EXIT
echo "$NEW_MATTERS" > "$NEW_MATTERS_FILE"

ENRICHED=$(python3 - "$LEGISTAR_API" "$NEW_MATTERS_FILE" <<'PYEOF'
import json, sys, subprocess, tempfile, os, urllib.request

api_base = sys.argv[1]
with open(sys.argv[2]) as f:
    matters = json.load(f)

def fetch_json(url):
    try:
        req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
        with urllib.request.urlopen(req, timeout=15) as r:
            return json.loads(r.read())
    except Exception:
        return []

def extract_pdf_text(url, max_chars=800):
    try:
        with tempfile.NamedTemporaryFile(suffix='.pdf', delete=False) as f:
            tmp = f.name
        req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
        with urllib.request.urlopen(req, timeout=30) as r:
            with open(tmp, 'wb') as f:
                f.write(r.read())
        result = subprocess.run(['pdftotext', tmp, '-'], capture_output=True, text=True, timeout=30)
        os.unlink(tmp)
        if result.returncode == 0:
            text = ' '.join(result.stdout.split())
            # Table-of-contents pages repeat these headings with dot-leader
            # page numbers before the real section — the LAST occurrence is
            # the actual body text, not the TOC entry.
            for section in ['RECOMMENDATION', 'BACKGROUND', 'SUMMARY', 'PURPOSE', 'Overview']:
                idx = text.rfind(section)
                if idx > 0:
                    return text[idx:idx + max_chars]
            return text[:max_chars]
    except Exception as e:
        return f"(PDF extraction failed: {e})"
    return ""

enriched = []
for m in matters:
    mid = m['MatterId']
    attachments = fetch_json(f"{api_base}/matters/{mid}/attachments")
    pdf_url = None
    for att in attachments:
        name = (att.get('MatterAttachmentName') or '').lower()
        url = att.get('MatterAttachmentHyperlink') or ''
        if url.endswith('.pdf') and any(k in name for k in ['council report', 'ctc memo', 'staff report', 'memo', 'summary report']):
            pdf_url = url
            break
    if not pdf_url and attachments:
        for att in attachments:
            if (att.get('MatterAttachmentHyperlink') or '').endswith('.pdf'):
                pdf_url = att['MatterAttachmentHyperlink']
                break

    m['_pdf_text'] = extract_pdf_text(pdf_url) if pdf_url else ''
    m['_pdf_url'] = pdf_url or ''
    m['_attachment_count'] = len(attachments)
    enriched.append(m)

print(json.dumps(enriched))
PYEOF
)

# ── 6. Generate blog post HTML ────────────────────────────────────────────────
POST_SLUG="${TODAY}-update"
POST_FILE="$REPO_DIR/posts/${POST_SLUG}.html"
ENRICHED_FILE=$(mktemp)
trap 'rm -f "$NEW_MATTERS_FILE" "$ENRICHED_FILE"' EXIT
echo "$ENRICHED" > "$ENRICHED_FILE"

python3 - "$ENRICHED_FILE" "$TODAY" "$POST_FILE" "$LEGISTAR_WEB" <<'PYEOF'
import json, sys

with open(sys.argv[1]) as f:
    matters = json.load(f)
today = sys.argv[2]
post_file = sys.argv[3]
legistar_web = sys.argv[4]
rows = ""
for m in sorted(matters, key=lambda x: x.get('MatterLastModifiedUtc', '') or ''):
    title = (m.get('MatterTitle') or '').replace('<', '&lt;').replace('>', '&gt;')
    mtype = m.get('MatterTypeName', '')
    status = m.get('MatterStatusName', '')
    file_no = m.get('MatterFile', '')
    modified = (m.get('MatterLastModifiedUtc') or '').split('T')[0]
    mid = m.get('MatterId')
    guid = m.get('MatterGuid')
    detail_url = f"{legistar_web}/LegislationDetail.aspx?ID={mid}&GUID={guid}" if mid and guid else None

    snippet = (m.get('_pdf_text') or '').strip()
    if snippet:
        cut = snippet[:600].replace('<', '&lt;').replace('>', '&gt;')
        detail_html = f'<div class="detail">{cut}{"..." if len(snippet) > 600 else ""}</div>'
    else:
        detail_html = '<div class="detail"><em>No staff report text available.</em></div>'

    links = []
    if detail_url:
        links.append(f'<a href="{detail_url}" target="_blank">Legistar record ↗</a>')
    if m.get('_pdf_url'):
        links.append(f'<a href="{m["_pdf_url"]}" target="_blank">staff report PDF ↗</a>')
    links_html = f'<div class="links">{" &middot; ".join(links)}</div>' if links else ''

    rows += f"""
    <li>
      <div class="date">{modified} — {file_no}</div>
      <div><strong>{title}</strong></div>
      <div class="body">Type: {mtype} &nbsp;|&nbsp; Status: {status}</div>
      {detail_html}
      {links_html}
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
    .timeline .detail {{ color: #444; font-size: 0.9em; margin-top: 0.6em; line-height: 1.5; }}
    .timeline .links {{ margin-top: 0.4em; font-size: 0.85em; }}
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

# ── 7. Update index.html (idempotent — skip if this slug is already listed) ──
python3 -c "
index = '$REPO_DIR/index.html'
slug = '${POST_SLUG}'
with open(index) as f: content = f.read()
if f'posts/{slug}.html' in content:
    print('Index already has this post, skipping insert.')
else:
    entry = '''    <li>
      <span class=\"date\">$TODAY</span><br>
      <a href=\"posts/{slug}.html\">Fiber/Broadband Update &mdash; $TODAY</a>
    </li>
    '''.format(slug=slug)
    content = content.replace('<ul class=\"post-list\">\n', '<ul class=\"post-list\">\n' + entry, 1)
    with open(index, 'w') as f: f.write(content)
    print('Index updated.')
"

# ── 8. Update state ────────────────────────────────────────────────────────────
python3 -c "
import json
s = json.load(open('$STATE_FILE'))
s['last_check'] = '$(date -u +%Y-%m-%dT%H:%M:%S)'
json.dump(s, open('$STATE_FILE','w'), indent=2)
"

# ── 9. Commit and push ────────────────────────────────────────────────────────
cd "$REPO_DIR"
git add -A
git commit -m "Auto-update: ${COUNT} new fiber/broadband matter(s) — ${TODAY}"
git push origin main
log "Pushed to GitHub."
log "Done."
