#!/bin/bash
# KLIERD live health check (Layer 2)
# Fetches each critical URL and verifies it serves expected content.
# Exits 0 if all healthy, 1 if any URL fails.
#
# Usage: ./.coco/health_check.sh
#        ./.coco/health_check.sh --quiet  (only output failures)

set -u
QUIET="${1:-}"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

FAIL=0
say() { [ "$QUIET" != "--quiet" ] && echo "$@"; }

# URL → minimum-bytes → must-contain string
declare -A URLS
URLS["https://trystackpro.com/"]="40000:KLIER"
URLS["https://trystackpro.com/apply.html"]="30000:KLIERD"
URLS["https://trystackpro.com/portal.html"]="800000:doLogin"
URLS["https://trystackpro.com/client-portal.html"]="70000:KLIERD"
URLS["https://trystackpro.com/privacy.html"]="6000:KLIERD"
URLS["https://trystackpro.com/terms.html"]="6000:KLIERD"

say "═══ KLIERD HEALTH CHECK $(date '+%Y-%m-%d %H:%M:%S') ═══"

for url in "${!URLS[@]}"; do
  spec="${URLS[$url]}"
  min_bytes="${spec%%:*}"
  must="${spec#*:}"

  # Cache-bust with a random query string
  cb_url="${url}?cb=$(date +%s%N)"
  body=$(curl -s -L --max-time 10 "$cb_url" 2>/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo -e "${RED}❌ $url — curl rc=$rc (network failure)${NC}"
    FAIL=$((FAIL+1))
    continue
  fi
  size=${#body}
  if [ "$size" -lt "$min_bytes" ]; then
    echo -e "${RED}❌ $url — size $size below minimum $min_bytes${NC}"
    FAIL=$((FAIL+1))
    continue
  fi
  if ! echo "$body" | grep -q "$must"; then
    echo -e "${RED}❌ $url — missing required marker: $must${NC}"
    FAIL=$((FAIL+1))
    continue
  fi
  say -e "${GREEN}✓ $url — $size bytes, marker found${NC}"
done

if [ "$FAIL" -eq 0 ]; then
  say -e "${GREEN}✅ All $(echo "${!URLS[@]}" | wc -w) URLs healthy${NC}"
  exit 0
else
  echo -e "${RED}❌ $FAIL URL(s) failed health check${NC}"
  exit 1
fi
