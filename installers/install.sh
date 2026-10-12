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
   https://raw.githubusercontent.com/*|https://github.com/*|https://release-assets.githubusercontent.com/*|https://objects.githubusercontent.com/*) ;;
   *) fail "Unapproved download URL: $url";;
  esac
  # Never let curl follow redirects itself; validate every destination first.
  status=$(curl -q --proto '=https' --tlsv1.2 --silent --show-error --connect-timeout 20 --max-time 300 \
   --header 'Cache-Control: no-cache' \
   --dump-header "$tmp/headers" --output "$output" --write-out '%{http_code}' "$url") || fail 'Download failed'
  case "$status" in
   200) return;;
   301|302|303|307|308)
    redirects=$((redirects+1)); [ "$redirects" -le 4 ] || fail 'Too many redirects'
    url=$(awk 'tolower($1)=="location:" {sub(/^[^:]*:[ \t]*/, "");sub(/\r$/, "");print}' "$tmp/headers")
    ;;
   *) fail "Download returned HTTP $status";;
  esac
 done
}
quote_sh() {
 printf "'"
 printf '%s' "$1" | sed "s/'/'\\\\''/g"
 printf "'"
}
path_hint() {
 if [ "$destination" = "$HOME/.local/bin" ]; then
  path_line='export PATH="$HOME/.local/bin:$PATH"'
 else
  quoted_destination=$(quote_sh "$destination")
  path_line="export PATH=$quoted_destination:\"\$PATH\""
 fi
 quoted_line=$(quote_sh "$path_line")
 printf '\n%s\n\n' 'Check which shell you use:'
 printf '  echo $SHELL\n\n'
 printf '%s\n\n' 'Choose the commands for your shell:'
 printf 'Zsh:\n'
 printf '%s\n' "  printf '%s\\n' $quoted_line >> \"\${ZDOTDIR:-\$HOME}/.zshrc\""
 printf '  source "${ZDOTDIR:-$HOME}/.zshrc"\n\n'
 printf 'Bash:\n'
 printf '%s\n' "  printf '%s\\n' $quoted_line >> ~/.bashrc"
 printf '  source ~/.bashrc\n\n'
 printf '%s\n\n' 'Verify the installation:'
 printf '  hyperbricks version\n\n'
 printf '%s\n' 'Note for Bash login terminals: your login profile must load ~/.bashrc'
 printf '%s\n' 'for this setting to apply automatically in future sessions.'
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
 if [ -z "$version" ]; then
  fetch 'https://raw.githubusercontent.com/hyperbricks/hyperbricks-builder/main/version.md' "$tmp/version.md"
  [ "$(awk 'END {print NR}' "$tmp/version.md")" = 1 ] || fail 'Invalid version file'
  version=$(cat "$tmp/version.md")
 fi
 printf '%s\n' "$version" | awk '
  NR != 1 {exit 1}
  !/^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-([0-9A-Za-z-]+\.)*[0-9A-Za-z-]+)?$/ {exit 1}
  {v=$0; sub(/^v[0-9]+\.[0-9]+\.[0-9]+-?/, "", v); n=split(v,a,"."); for(i=1;i<=n;i++) if(a[i] ~ /^0[0-9]+$/) exit 1}
 ' || fail 'Invalid version tag'
 tag=$version
 archive="hyperbricks_${tag}_${os}_${arch}.tar.gz"
 base="https://github.com/hyperbricks/hyperbricks-builder/releases/download/$tag"
 fetch "$base/$archive.sha256" "$tmp/checksum"
 expected=$(awk -v name="$archive" 'NF==2 && $2==name {n++;hash=$1} END {if(n!=1 || NR!=1) exit 1;print hash}' "$tmp/checksum") || fail 'Invalid checksum file'
 [ "${#expected}" = 64 ] || fail 'Invalid SHA-256'
 case "$expected" in *[!0-9a-f]*) fail 'Invalid SHA-256';; esac
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
 path_hint
}
# Entry point
main "$@"
