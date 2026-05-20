#!/bin/bash
# KLIERD pre-push validator — Layer 1 guardrail (Coco)
# Blocks bad commits BEFORE they reach the repo.
#
# Checks performed:
#   1. HTML structure (open/close tags balanced)
#   2. Critical file integrity (size, required markers)
#   3. JavaScript syntax (node --check on inline scripts)
#   4. Compliance scrub (no forbidden phrases on client-facing HTML)
#   5. Brand check (no leftover StackPro / CBG Funds / Cole Benefit Group on client copy)
#
# Usage: ./validate.sh [path-to-repo-root]
# Exits with 0 on success, 1 on any failure.

set -u
REPO="${1:-.}"
cd "$REPO" || exit 1

FAIL=0
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

fail() { echo -e "${RED}❌ $1${NC}"; FAIL=$((FAIL+1)); }
ok()   { echo -e "${GREEN}✓ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠ $1${NC}"; }
info() { echo -e "${BLUE}→ $1${NC}"; }

echo "═══════════════════════════════════════════════════════════════"
echo "  KLIERD PRE-PUSH VALIDATOR (Layer 1)"
echo "═══════════════════════════════════════════════════════════════"

# Critical files we always check
CRITICAL_FILES=(index.html apply.html portal.html client-portal.html)
CLIENT_FACING_FILES=(index.html apply.html client-portal.html privacy.html terms.html)

# Minimum sizes (bytes) — anything smaller is suspicious
declare -A MIN_SIZE
MIN_SIZE[index.html]=20000
MIN_SIZE[apply.html]=20000
MIN_SIZE[portal.html]=200000
MIN_SIZE[client-portal.html]=20000
MIN_SIZE[privacy.html]=3000
MIN_SIZE[terms.html]=3000

# Required content markers (file → must-contain string)
declare -A MARKER
MARKER[index.html]="KLIER"
MARKER[apply.html]="Apply"
MARKER[portal.html]="doLogin"
MARKER[client-portal.html]="Client Portal"

# ─── 1. HTML STRUCTURE ──────────────────────────────────────────────
info "Check 1/5 — HTML structure"
for f in "${CRITICAL_FILES[@]}"; do
  [ -f "$f" ] || { warn "$f not present (skipping)"; continue; }
  open=$(grep -c '<html' "$f")
  close=$(grep -c '</html' "$f")
  bodyo=$(grep -c '<body' "$f")
  bodyc=$(grep -c '</body' "$f")
  if [ "$open" -lt 1 ] || [ "$close" -lt 1 ]; then
    fail "$f missing <html> or </html>"
  elif [ "$bodyo" -lt 1 ] || [ "$bodyc" -lt 1 ]; then
    fail "$f missing <body> or </body>"
  else
    ok "$f structure OK"
  fi
done

# ─── 2. FILE SIZE + MARKERS ────────────────────────────────────────
echo ""
info "Check 2/5 — File size + required markers"
for f in "${CRITICAL_FILES[@]}"; do
  [ -f "$f" ] || continue
  sz=$(wc -c < "$f")
  min="${MIN_SIZE[$f]:-5000}"
  if [ "$sz" -lt "$min" ]; then
    fail "$f is $sz bytes (minimum: $min) — likely corrupted or empty"
  else
    ok "$f size $sz bytes"
  fi
  if [ -n "${MARKER[$f]:-}" ]; then
    if grep -q "${MARKER[$f]}" "$f"; then
      ok "$f contains required marker: ${MARKER[$f]}"
    else
      fail "$f missing required marker: ${MARKER[$f]}"
    fi
  fi
done

# ─── 3. JAVASCRIPT SYNTAX ──────────────────────────────────────────
echo ""
info "Check 3/5 — JavaScript syntax (node --check on inline scripts)"
if ! command -v node >/dev/null 2>&1; then
  warn "node not installed — skipping JS check"
else
  for f in "${CRITICAL_FILES[@]}"; do
    [ -f "$f" ] || continue
    # Extract each <script>...</script> block and validate
    js_fail=0
    python3 - "$f" << 'PYEOF' > /tmp/_validate_js_out 2>&1
import re, subprocess, sys, tempfile, os
fp = sys.argv[1]
with open(fp) as fh: html = fh.read()
scripts = re.findall(r'<script(?:[^>]*)>(.*?)</script>', html, flags=re.DOTALL)
fail = 0
for i, s in enumerate(scripts):
    if 'src=' in scripts[i][:80] or not s.strip(): continue
    with tempfile.NamedTemporaryFile(suffix='.js', mode='w', delete=False) as tf:
        tf.write(s); tn = tf.name
    r = subprocess.run(['node','--check',tn], capture_output=True, text=True)
    if r.returncode != 0:
        print(f"BLOCK_{i}_FAIL"); fail += 1
    os.unlink(tn)
sys.exit(fail)
PYEOF
    if [ $? -eq 0 ]; then
      ok "$f JS syntax valid"
    else
      fail "$f has JS syntax error — see /tmp/_validate_js_out"
    fi
  done
fi

# ─── 4. COMPLIANCE SCRUB ───────────────────────────────────────────
echo ""
info "Check 4/5 — Compliance scrub (Golden Rules #3, #4, #5, #8, #11)"

# Hard-forbidden anywhere on client-facing HTML
HARD_FORBIDDEN=(
  "credit sweep"
  "clean credit"
  "fix credit"
  "guaranteed approval"
  "we will get you funded"
  "Cole Benefit Group"
  "AI-powered"
  "AI-driven"
  "AI Lender"
  "con IA"
)
for f in "${CLIENT_FACING_FILES[@]}"; do
  [ -f "$f" ] || continue
  for phrase in "${HARD_FORBIDDEN[@]}"; do
    count=$(grep -ic "$phrase" "$f" 2>/dev/null)
    if [ "$count" -gt 0 ]; then
      fail "$f contains forbidden phrase: \"$phrase\" ($count occurrence(s))"
    fi
  done
done

# "credit repair" — allowed ONLY in disclosure context
for f in "${CLIENT_FACING_FILES[@]}"; do
  [ -f "$f" ] || continue
  bad=$(grep -i "credit repair" "$f" | grep -ivE "not.{0,5}(a |an |operate|operating)|do NOT|is this a credit|not a credit repair|never charge|don't operate|under CROA" | wc -l)
  if [ "$bad" -gt 0 ]; then
    fail "$f has \"credit repair\" in non-disclosure context ($bad line(s))"
  fi
done

# Score thresholds (Rule #11 — proprietary IP)
for f in "${CLIENT_FACING_FILES[@]}"; do
  [ -f "$f" ] || continue
  if grep -qE "620\+ score|640 threshold|score threshold[^s]" "$f"; then
    fail "$f reveals proprietary score threshold (Rule #11)"
  fi
done

ok "Compliance scrub complete"

# ─── 5. BRAND CHECK ────────────────────────────────────────────────
echo ""
info "Check 5/5 — Brand check (KLIERD-only public branding)"
for f in "${CLIENT_FACING_FILES[@]}"; do
  [ -f "$f" ] || continue
  # StackPro should NOT appear visibly (only in internal var names which are uncommon)
  visible_stackpro=$(grep -c "StackPro" "$f")
  if [ "$visible_stackpro" -gt 0 ]; then
    # Allow it in JS string contexts (sp_api_url etc.) only — flag for review
    warn "$f contains $visible_stackpro StackPro mention(s) — review (may be code-internal)"
  fi
  cbg_funds=$(grep -c "CBG Funds" "$f")
  if [ "$cbg_funds" -gt 0 ]; then
    # Exception: portal.html staff compliance instruction is allowed to mention CBG Funds
    if [ "$f" = "portal.html" ]; then
      ok "$f CBG Funds mentions ($cbg_funds) — internal staff context allowed"
    else
      fail "$f contains visible CBG Funds branding ($cbg_funds) — should be KLIERD"
    fi
  fi
done

# ─── SUMMARY ───────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════"
if [ "$FAIL" -eq 0 ]; then
  echo -e "${GREEN}  ✅ ALL CHECKS PASSED — Safe to push${NC}"
  echo "═══════════════════════════════════════════════════════════════"
  exit 0
else
  echo -e "${RED}  ❌ $FAIL FAILURE(S) — PUSH BLOCKED${NC}"
  echo "═══════════════════════════════════════════════════════════════"
  echo "Fix the issues above before pushing. To bypass (DANGEROUS):"
  echo "  COCO_BYPASS_VALIDATE=1 ./.coco/validate.sh"
  exit 1
fi
