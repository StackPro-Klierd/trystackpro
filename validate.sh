#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# KLIERD — Pre-deploy validator (Layer 1)
# ═══════════════════════════════════════════════════════════════
# Run BEFORE every cPanel upload or git push.
# Blocks bad files from ever reaching production.
#
# Checks for each .html file:
#   1. JS syntax inside <script> blocks (via node --check)
#   2. <script> tag balance
#   3. Compliance words (StackPro / CBG Funds / credit repair / etc.)
#   4. Federal disclosure (FCRA) presence on dispute-referencing pages
#   5. "Results are not typical and may vary" presence
#
# Exit code 0 = safe to deploy. Non-zero = STOP, fix the issue first.
# ═══════════════════════════════════════════════════════════════

cd "$(dirname "$0")"

# Every HTML file shipped to klierd.com is scanned
FILES="index.html apply.html portal.html client-portal.html dispute.html"
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

  # 3. Compliance scan — forbidden client-visible language (HARD FAIL)
  # NOTE: "credit repair" is allowed only in defensive disclaimer context
  # ("not a credit repair", "does not operate as a credit repair", "never credit repair").
  # All other uses of "credit repair" hard-fail.
  COMP_ERRS=0
  HARD_FAILS=(
    "credit sweep"
    "clean credit"
    "guaranteed approval"
    "we will get you funded"
    "CBG Funds"
    "Cole Benefit Group"
    "AI-driven"
    "AI-powered"
    "trystackpro"
  )
  for WORD in "${HARD_FAILS[@]}"; do
    HITS=$(grep -c -i "$WORD" "$FILE" 2>/dev/null | head -1 | tr -d ' \n')
    HITS=${HITS:-0}
    if [ "$HITS" -gt 0 ] 2>/dev/null; then
      echo "  ❌ COMPLIANCE: '$WORD' found $HITS time(s)"
      ERRORS=$((ERRORS+1))
      COMP_ERRS=$((COMP_ERRS+1))
    fi
  done

  # 3b. "credit repair" — must only appear in approved defensive contexts
  CR_TOTAL=$(grep -c -i "credit repair" "$FILE" 2>/dev/null | head -1 | tr -d ' \n')
  CR_TOTAL=${CR_TOTAL:-0}
  if [ "$CR_TOTAL" -gt 0 ] 2>/dev/null; then
    # Allowed defensive patterns (case-insensitive)
    CR_OK=$(grep -i -E "not (a |operate as a )credit repair|does not operate as a credit repair|never credit repair|misrepresent.*credit repair|use the term .credit repair|Claim to be a Credit Repair" "$FILE" 2>/dev/null | wc -l | tr -d ' \n')
    CR_BAD=$((CR_TOTAL - CR_OK))
    if [ "$CR_BAD" -gt 0 ]; then
      echo "  ❌ COMPLIANCE: 'credit repair' found in $CR_BAD non-defensive context(s)"
      grep -n -i "credit repair" "$FILE" | grep -v -i -E "not (a |operate as a )credit repair|does not operate as a credit repair|never credit repair|misrepresent.*credit repair|use the term .credit repair|Claim to be a Credit Repair" | head -3 | sed 's/^/    /' | cut -c1-160
      ERRORS=$((ERRORS+1))
      COMP_ERRS=$((COMP_ERRS+1))
    else
      echo "  ℹ️  'credit repair' x$CR_TOTAL — all in approved defensive context"
    fi
  fi

  # Soft warn — known-pending infra references (Mill's scope to migrate)
  SOFT_HITS=$(grep -c -i "stackpro-api-production" "$FILE" 2>/dev/null | head -1 | tr -d ' \n')
  SOFT_HITS=${SOFT_HITS:-0}
  if [ "$SOFT_HITS" -gt 0 ]; then
    echo "  ⚠️  INFRA pending: 'stackpro-api-production' x$SOFT_HITS (Railway rename — Mill's scope)"
  fi

  if [ "$COMP_ERRS" -eq 0 ]; then
    echo "  ✅ Compliance scan: clean"
  fi

  # 4. Required disclosure on dispute-referencing pages
  if [ "$FILE" = "client-portal.html" ] || [ "$FILE" = "dispute.html" ]; then
    if grep -q -i -E "Fair Credit Reporting Act|FCRA" "$FILE"; then
      echo "  ✅ FCRA disclosure present"
    else
      echo "  ⚠️  FCRA disclosure NOT FOUND (recommended on dispute-referencing pages)"
    fi
  fi

  # 5. Required "Results not typical" disclaimer
  if ! grep -q -i "Results are not typical" "$FILE"; then
    echo "  ⚠️  'Results are not typical and may vary' NOT FOUND"
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
