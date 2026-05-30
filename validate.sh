#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# KLIERD / StackPro — Pre-deploy validator
# ═══════════════════════════════════════════════════════════════
# Run BEFORE every cPanel upload or git push.
# Blocks bad files from ever reaching production.
#
# Checks for each .html file:
#   1. JS syntax inside <script> blocks (via node --check)
#   2. <script> tag balance
#   3. Compliance words ("credit sweep", "guaranteed approval", etc.)
#   4. CROA disclaimer presence on client-portal.html
#
# Exit code 0 = safe to deploy. Non-zero = STOP, fix the issue first.
# ═══════════════════════════════════════════════════════════════

cd "$(dirname "$0")"

FILES="portal.html client-portal.html index.html"
ERRORS=0

echo "═══════════════════════════════════════════════════════════════"
echo "  KLIERD Pre-Deploy Validator — $(date)"
echo "═══════════════════════════════════════════════════════════════"

for FILE in $FILES; do
  if [ ! -f "$FILE" ]; then
    echo "❌ [$FILE] FILE NOT FOUND"
    ERRORS=$((ERRORS+1))
    continue
  fi

  echo ""
  echo "── $FILE ──"
  SIZE=$(wc -c < "$FILE" | tr -d ' ')
  echo "  Size: $SIZE bytes"

  # 1. Extract all inline <script> blocks and run node --check on each
  TMPDIR="/tmp/klierd_validate_$$_${FILE%.*}"
  rm -rf "$TMPDIR"
  mkdir -p "$TMPDIR"
  COUNT=$(python3 -c "
import re
with open('$FILE') as f: html=f.read()
blocks=re.findall(r'<script>(.*?)</script>', html, re.DOTALL)
for i,b in enumerate(blocks):
    open(f'$TMPDIR/s_{i}.js','w').write(b)
print(len(blocks))
" 2>/dev/null)
  echo "  Inline scripts: $COUNT"

  for f in "$TMPDIR"/s_*.js; do
    [ -f "$f" ] || continue
    BNAME=$(basename "$f")
    ERR=$(node --check "$f" 2>&1)
    if [ -n "$ERR" ]; then
      echo "  ❌ $BNAME — SYNTAX ERROR:"
      echo "$ERR" | head -8 | sed 's/^/      /'
      ERRORS=$((ERRORS+1))
    else
      echo "  ✅ $BNAME — syntax OK"
    fi
  done
  rm -rf "$TMPDIR"

  # 2. <script> tag balance check
  SCR_OPEN=$(grep -o '<script' "$FILE" | wc -l | tr -d ' ')
  SCR_CLOSE=$(grep -o '</script>' "$FILE" | wc -l | tr -d ' ')
  if [ "$SCR_OPEN" -ne "$SCR_CLOSE" ]; then
    echo "  ❌ <script> imbalance: $SCR_OPEN open / $SCR_CLOSE close"
    ERRORS=$((ERRORS+1))
  else
    echo "  ✅ <script> balanced: $SCR_OPEN"
  fi

  # 3. Compliance scan — forbidden words
  COMP_ERRS=0
  for WORD in "credit sweep" "guaranteed approval" "we will get you funded"; do
    HITS=$(grep -c -i "$WORD" "$FILE" 2>/dev/null | head -1 | tr -d ' \n')
    HITS=${HITS:-0}
    if [ "$HITS" -gt 0 ] 2>/dev/null; then
      echo "  ❌ COMPLIANCE: '$WORD' found $HITS time(s)"
      ERRORS=$((ERRORS+1))
      COMP_ERRS=$((COMP_ERRS+1))
    fi
  done
  if [ "$COMP_ERRS" -eq 0 ]; then
    echo "  ✅ Compliance scan: clean"
  fi

  # 3b. FORBIDDEN LENDER scan — Teka 2026-05-30 lock (Cece hard-removed 14 lenders)
  # Whole-word match so 'mercury-mining' or 'relay-state' don't false-trigger.
  LENDER_ERRS=0
  for LENDER in "Brex" "Ramp" "OnDeck" "Mercury" "Divvy" "Stripe Corp" "Nova Credit" "Petal 1" "Petal 2"; do
    HITS=$(grep -c -w "$LENDER" "$FILE" 2>/dev/null | head -1 | tr -d ' \n')
    HITS=${HITS:-0}
    if [ "$HITS" -gt 0 ] 2>/dev/null; then
      echo "  ❌ FORBIDDEN LENDER: '$LENDER' found $HITS time(s) — Teka said remove this"
      ERRORS=$((ERRORS+1))
      LENDER_ERRS=$((LENDER_ERRS+1))
    fi
  done
  if [ "$LENDER_ERRS" -eq 0 ]; then
    echo "  ✅ Forbidden lender scan: clean"
  fi

  # 4. CROA disclaimer presence (client-portal.html only)
  if [ "$FILE" = "client-portal.html" ]; then
    if grep -q -i "not a credit repair" "$FILE"; then
      echo "  ✅ CROA disclaimer present"
    else
      echo "  ⚠️  CROA disclaimer NOT FOUND (recommended)"
    fi
  fi
done

echo ""
echo "═══════════════════════════════════════════════════════════════"
if [ "$ERRORS" -eq 0 ]; then
  echo "  ✅ ALL CHECKS PASSED — Safe to deploy"
  echo "═══════════════════════════════════════════════════════════════"
  exit 0
else
  echo "  ❌ $ERRORS ERROR(S) FOUND — DO NOT DEPLOY"
  echo "═══════════════════════════════════════════════════════════════"
  exit 1
fi
