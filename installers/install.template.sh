#!/bin/sh
# HyperBricks installer. Verify this script's SHA-256 before running it.
set -eu
umask 077
fail() { printf '%s\n' "Error: $*" >&2; exit 1; }
sha256() {
 if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
 else shasum -a 256 "$1" | awk '{print $1}'; fi
}
fetch() {
 url=$1; output=$2; redirects=0
 while :; do
  case "$url" in
   https://api.github.com/*|https://github.com/*|https://release-assets.githubusercontent.com/*|https://objects.githubusercontent.com/*) ;;
   *) fail "Unapproved download URL: $url";;
  esac
  # Never let curl follow redirects itself; validate every destination first.
  status=$(curl -q --proto '=https' --tlsv1.2 --silent --show-error --connect-timeout 20 --max-time 300 \
   --header 'Accept: application/vnd.github+json' --header 'Cache-Control: no-cache' \
   --dump-header "$tmp/headers" --output "$output" --write-out '%{http_code}' "$url") || fail 'Download failed'
  case "$status" in
   200) return;;
   301|302|303|307|308)
    case "$url" in https://api.github.com/*) fail 'API redirect refused';; esac
    redirects=$((redirects+1)); [ "$redirects" -le 4 ] || fail 'Too many redirects'
    url=$(awk 'tolower($1)=="location:" {sub(/^[^:]*:[ \t]*/, "");sub(/\r$/, "");print}' "$tmp/headers")
    ;;
   *) fail "Download returned HTTP $status";;
  esac
 done
}
main() {
 version=''; destination="${HOME:?HOME is required}/.local/bin"
 while [ "$#" -gt 0 ]; do
  case "$1" in
   --version) [ "$#" -ge 2 ] || fail '--version needs a tag'; version=$2; shift 2;;
   --install-dir) [ "$#" -ge 2 ] || fail '--install-dir needs a path'; destination=$2; shift 2;;
   --help) printf '%s\n' 'Usage: sh install.sh [--version vX.Y.Z-beta] [--install-dir /absolute/path]'; return;;
   *) fail "Unknown argument: $1";;
  esac
 done
 case "$destination" in /*) ;; *) fail 'Install directory must be absolute';; esac
 case "$version" in *[!a-zA-Z0-9.-]*) fail 'Invalid version tag';; esac
 command -v curl >/dev/null || fail 'curl is required'
 command -v awk >/dev/null || fail 'awk is required'
 command -v tar >/dev/null || fail 'tar is required'
 if ! command -v sha256sum >/dev/null && ! command -v shasum >/dev/null; then fail 'SHA-256 tool required'; fi
 case "$(uname -s)" in Darwin) os=darwin;; Linux) os=linux;; *) fail 'Use install.ps1 on Windows';; esac
 case "$(uname -m)" in x86_64|amd64) arch=amd64;; arm64|aarch64) arch=arm64;; *) fail 'Unsupported architecture';; esac
 tmp=$(mktemp -d "${TMPDIR:-/tmp}/hyperbricks-install.XXXXXXXX") || fail 'Cannot create temporary directory'
 stage=''
 trap 'rm -rf "$tmp"; if [ -n "$stage" ]; then rm -f "$stage"; fi' EXIT
 trap 'exit 1' HUP INT TERM
 cat > "$tmp/releases.awk" <<'HB_RELEASES_AWK'
@@RELEASES_AWK@@
HB_RELEASES_AWK
 api=https://api.github.com/repos/hyperbricks/hyperbricks
 : > "$tmp/releases.json"
 if [ -n "$version" ]; then
  fetch "$api/releases/tags/$version" "$tmp/page"
  printf '[\n' >> "$tmp/releases.json"; cat "$tmp/page" >> "$tmp/releases.json"; printf '\n]\n' >> "$tmp/releases.json"
 else
  page=1
  while :; do
   fetch "$api/releases?per_page=100&page=$page" "$tmp/page"
   cat "$tmp/page" >> "$tmp/releases.json"; printf '\n' >> "$tmp/releases.json"
   # GitHub supplies a next relation while there are more pages.
   if ! awk 'tolower($1)=="link:" && /rel="next"/ {found=1} END {exit !found}' "$tmp/headers"; then break; fi
   page=$((page+1)); [ "$page" -le 1000 ] || fail 'Release listing exceeds pagination limit'
  done
 fi
 selection=$(awk -v wanted="$version" -v platform="${os}_${arch}" -f "$tmp/releases.awk" "$tmp/releases.json") || fail 'Release selection failed'
 set -- $selection
 [ "$#" -eq 3 ] || fail 'Missing release checksums'
 tag=$1; archive_hash=$2; sidecar_hash=$3
 archive="hyperbricks_${tag}_${os}_${arch}.tar.gz"
 base="https://github.com/hyperbricks/hyperbricks/releases/download/$tag"
 fetch "$base/$archive.sha256" "$tmp/checksum"
 [ "$(sha256 "$tmp/checksum")" = "$sidecar_hash" ] || fail 'Checksum file differs from GitHub digest'
 expected=$(awk -v name="$archive" 'NF==2 && $2==name {n++;hash=$1} END {if(n!=1 || NR!=1) exit 1;print hash}' "$tmp/checksum") || fail 'Invalid checksum file'
 [ "$expected" = "$archive_hash" ] || fail 'Archive checksum differs from GitHub digest'
 fetch "$base/$archive" "$tmp/archive"
 [ "$(sha256 "$tmp/archive")" = "$expected" ] || fail 'Archive SHA-256 mismatch'
 tar -tzf "$tmp/archive" > "$tmp/members" || fail 'Invalid archive'
 [ "$(cat "$tmp/members")" = hyperbricks ] || fail 'Unexpected archive members'
 tar -tvzf "$tmp/archive" > "$tmp/types" || fail 'Invalid archive metadata'
 [ "$(wc -l < "$tmp/types" | tr -d ' ')" = 1 ] || fail 'Unexpected archive entries'
 case "$(cat "$tmp/types")" in -*) ;; *) fail 'Archive member is not a regular file';; esac
 mkdir -p "$destination"
 [ ! -L "$destination/hyperbricks" ] || fail 'Refusing to replace a symlink'
 [ ! -d "$destination/hyperbricks" ] || fail 'Install target is a directory'
 stage=$(mktemp "$destination/.hyperbricks.XXXXXXXX") || fail 'Cannot stage executable'
 # Extract only the verified regular member, to stdout, never archive paths.
 tar -xOzf "$tmp/archive" hyperbricks > "$stage" || fail 'Extraction failed'
 chmod 755 "$stage"
 "$stage" version > "$tmp/version" || fail 'Downloaded executable did not run'
 awk -v tag="$tag" '$0==tag {found=1} END {exit !found}' "$tmp/version" || fail 'Executable version differs from release'
 mv -f "$stage" "$destination/hyperbricks"; stage=''
 printf 'Installed HyperBricks %s: %s/hyperbricks\n' "$tag" "$destination"
 printf 'Add this directory to PATH if needed: %s\n' "$destination"
}
# Entry point
main "$@"
