#!/usr/bin/env bash
# The caller checks out SOURCE_REF, or upstream main when it is empty.
set -euo pipefail
source_dir=${1:?source checkout required}
tag=''
mode=test
if [[ -z "${SOURCE_REF:-}" ]]; then
  tag=$(bash "$(dirname "$0")/latest-tag.sh" "$source_dir")
  sha=$(git -C "$source_dir" rev-parse "refs/tags/${tag}^{commit}")
  mode=release
else
  sha=$(git -C "$source_dir" rev-parse 'HEAD^{commit}')
fi
version=$(git -C "$source_dir" show "${sha}:assets/version.md" | tr -d '\r\n')
[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || {
  echo 'Invalid embedded source version' >&2
  exit 1
}
if [[ "$mode" == release && "$version" != "$tag" ]]; then
  echo 'Tag and embedded source version differ' >&2
  exit 1
fi
printf 'tag=%s\nsha=%s\nversion=%s\nmode=%s\n' "$tag" "$sha" "$version" "$mode"
