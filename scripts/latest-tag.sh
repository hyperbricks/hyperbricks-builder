#!/usr/bin/env bash
# The caller must first check out the freshly fetched upstream main.
set -euo pipefail
repo="${1:?Usage: latest-tag.sh SOURCE_CHECKOUT}"
tags="$(git -C "$repo" -c versionsort.suffix=- tag --merged HEAD --sort=-version:refname --list 'v[0-9]*')"
while IFS= read -r tag; do
  if [[ "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$ ]]; then
    printf '%s\n' "$tag"
    exit 0
  fi
done <<< "$tags"
printf 'No version tag found on main.\n' >&2
exit 1
