#!/usr/bin/env bash
# SCRIPT: test_docs_assets.sh
# DESCRIPTION: Every image the site references exists, and is the size it claims.
# USAGE: bash tests/test_docs_assets.sh
#
# The width and height attributes were written by hand and the screenshots were
# cropped afterwards, so all six declared a size they did not have. A browser
# reserves space from those numbers, which is the layout shift they exist to
# prevent. Nothing failed; the page simply jumped.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
checks=0
failures=0

note() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }
pass() { checks=$((checks + 1)); }

for page in "$ROOT"/docs/*.html; do
  # src, width and height, in that order, for local images only.
  while IFS='|' read -r src width height; do
    [ -n "$src" ] || continue
    case "$src" in http*) continue ;; esac
    file="$ROOT/docs/$src"

    if [ ! -f "$file" ]; then
      note "$(basename "$page") references a missing image: $src"
      continue
    fi
    pass

    if [ -z "$width" ] || [ -z "$height" ]; then
      continue
    fi
    if ! command -v identify >/dev/null 2>&1; then
      continue
    fi
    actual="$(identify -format '%w %h' "$file" 2>/dev/null)" || continue
    aw="${actual%% *}"; ah="${actual##* }"
    if [ "$aw" != "$width" ] || [ "$ah" != "$height" ]; then
      note "$src declares ${width}x${height} but is ${aw}x${ah}; run scripts/make_screenshots.sh"
      continue
    fi
    pass
  done < <(
    grep -o '<img[^>]*>' "$page" 2>/dev/null | while IFS= read -r tag; do
      src="$(printf '%s' "$tag" | grep -o 'src="[^"]*"' | head -1 | cut -d'"' -f2)"
      w="$(printf '%s' "$tag" | grep -o 'width="[0-9]*"' | head -1 | cut -d'"' -f2)"
      h="$(printf '%s' "$tag" | grep -o 'height="[0-9]*"' | head -1 | cut -d'"' -f2)"
      printf '%s|%s|%s\n' "$src" "$w" "$h"
    done
  )
done

# Every screenshot committed should be used, or it is dead weight in a git
# repository that will never be noticed again.
if [ -d "$ROOT/docs/assets/screenshots" ]; then
  for shot in "$ROOT"/docs/assets/screenshots/*.png; do
    [ -e "$shot" ] || continue
    name="$(basename "$shot")"
    if ! grep -q "screenshots/$name" "$ROOT"/docs/*.html 2>/dev/null; then
      note "docs/assets/screenshots/$name is committed but referenced by no page"
      continue
    fi
    pass
  done
fi

if [ "$failures" -eq 0 ]; then
  printf 'docs_assets: %s checks passed\n' "$checks"
else
  printf 'docs_assets: %s of %s checks FAILED\n' "$failures" "$((checks + failures))" >&2
  exit 1
fi
