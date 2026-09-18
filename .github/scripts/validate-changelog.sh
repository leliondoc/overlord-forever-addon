#!/usr/bin/env bash
# Valide CHANGELOG.md : une seule entete semver ; doit correspondre au tag si fourni.
set -euo pipefail

CHANGELOG="${1:-CHANGELOG.md}"
EXPECTED_TAG="${2:-}"

if [ ! -f "$CHANGELOG" ]; then
  echo "ERREUR: fichier absent : $CHANGELOG" >&2
  exit 1
fi

mapfile -t versions < <(grep -E '^[0-9]+\.[0-9]+(\.[0-9]+)?$' "$CHANGELOG" || true)
count="${#versions[@]}"

if [ "$count" -ne 1 ]; then
  echo "ERREUR: $CHANGELOG doit contenir exactement une ligne de version (semver seul)." >&2
  echo "       Trouve: $count ligne(s)." >&2
  if [ "$count" -gt 0 ]; then
    printf '       Versions: %s\n' "${versions[*]}" >&2
  fi
  exit 1
fi

version="${versions[0]}"

if [ -n "$EXPECTED_TAG" ] && [ "$version" != "$EXPECTED_TAG" ]; then
  echo "ERREUR: version dans $CHANGELOG ($version) != tag Git ($EXPECTED_TAG)." >&2
  exit 1
fi

echo "OK: $CHANGELOG — version $version"
