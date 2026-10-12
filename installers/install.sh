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
# Strict JSON reader and SemVer selector. Only expected release fields are used.
function die(s) { print "Invalid release metadata: " s > "/dev/stderr"; exit 1 }
function ws() { while (substr(src,pos,1) ~ /[ \t\r\n]/ && pos<=length(src)) pos++ }
function str(   c,e,out,h,i,n) {
 if (substr(src,pos++,1)!="\"") die("string expected")
 out=""
 while(pos<=length(src)) {
  c=substr(src,pos++,1)
  if(c=="\"") return out
  if(c=="\\") {
   e=substr(src,pos++,1)
   if(e=="u") {
    h=substr(src,pos,4); if(h !~ /^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$/) die("unicode escape")
    pos+=4; n=0; h=tolower(h)
    for(i=1;i<=4;i++) n=n*16+index("0123456789abcdef",substr(h,i,1))-1
    c=(n>=32 && n<127)?sprintf("%c",n):"?"
   } else if(e=="\"" || e=="\\" || e=="/") c=e
   else if(e ~ /^[bfnrt]$/) c="?"
   else die("escape")
  } else if(c ~ /[[:cntrl:]]/) die("control character")
  out=out c
 }
 die("unterminated string")
}
function field(path,v,   a,n,r,k) {
 n=split(path,a,"/"); r=a[2]; k=a[3]
 if(n==3 && (k=="tag_name" || k=="draft")) data[r,k]=v
 if(n==5 && k=="assets") asset[r,a[4],a[5]]=v
}
function value(path,depth,   c,k,v,i) {
 if(depth>80) die("nesting")
 ws(); c=substr(src,pos,1)
 if(c=="{") {
  pos++; ws(); if(substr(src,pos,1)=="}") {pos++;return}
  while(1) {
   ws();k=str();ws();if(substr(src,pos++,1)!=":") die("colon")
   value(path "/" k,depth+1);ws();c=substr(src,pos++,1)
   if(c=="}") return
   if(c!=",") die("object separator")
  }
 } else if(c=="[") {
  pos++;ws();if(substr(src,pos,1)=="]") {pos++;return}
  i=0
  while(1) {
   if(depth==0) value("/" ++count,depth+1); else value(path "/" i++,depth+1)
   ws();c=substr(src,pos++,1);if(c=="]") return
   if(c!=",") die("array separator")
  }
 } else {
  if(c=="\"") v=str()
  else {
   v="";while(pos<=length(src) && substr(src,pos,1) !~ /[ \t\r\n,}\]]/) v=v substr(src,pos++,1)
   if(v!="true" && v!="false" && v!="null" && v !~ /^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$/) die("scalar")
  }
  field(path,v)
 }
}
function numeric(a,b) { if(length(a)!=length(b)) return length(a)>length(b)?1:-1; return a==b?0:("x" a>"x" b?1:-1) }
function valid(t,   b,a,i,n) {
 if(t !~ /^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?$/) return 0
 b=t;sub(/^[^-]*-?/,"",b)
 if(b!="") {n=split(b,a,".");for(i=1;i<=n;i++) if(a[i]=="" || a[i] ~ /^0[0-9]+$/) return 0}
 return 1
}
function compare(a,b,   aa,bb,pa,pb,na,nb,i,c) {
 pa=a;pb=b;sub(/^[^-]*-?/,"",pa);sub(/^[^-]*-?/,"",pb)
 sub(/-.*/,"",a);sub(/-.*/,"",b);sub(/^v/,"",a);sub(/^v/,"",b)
 split(a,aa,".");split(b,bb,".")
 for(i=1;i<=3;i++){c=numeric(aa[i],bb[i]);if(c) return c}
 if(pa==pb) return 0
 if(pa=="") return 1
 if(pb=="") return -1
 na=split(pa,aa,".");nb=split(pb,bb,".")
 for(i=1;i<=na && i<=nb;i++) {
  if(aa[i]==bb[i]) continue
  if(aa[i] ~ /^[0-9]+$/ && bb[i] ~ /^[0-9]+$/) return numeric(aa[i],bb[i])
  if(aa[i] ~ /^[0-9]+$/) return -1
  if(bb[i] ~ /^[0-9]+$/) return 1
  return "x" aa[i]>"x" bb[i]?1:-1
 }
 return na>nb?1:-1
}
function hash(v) {return length(v)==71 && v ~ /^sha256:[0-9a-f]+$/}
{src=src $0 "\n"}
END {
 pos=1; ws(); while(pos<=length(src)){if(substr(src,pos,1)!="[") die("release array expected");value("",0);ws()}
 split("darwin_amd64 darwin_arm64 linux_amd64 linux_arm64 windows_amd64",platforms," ")
 for(r=1;r<=count;r++) {
  tag=data[r,"tag_name"];if(data[r,"draft"]!="false" || !valid(tag)) continue
  if(wanted!="" && tag!=wanted) continue
  delete names
  for(k in asset){split(k,parts,SUBSEP);if(parts[1]==r && parts[3]=="name") {
   name=asset[k];digest=asset[r,parts[2],"digest"]
   if(asset[r,parts[2],"state"]=="uploaded" && hash(digest)) names[name]=substr(digest,8)
  }}
  complete=1
  for(i=1;i<=5;i++){ext=platforms[i] ~ /^windows/?".zip":".tar.gz";name="hyperbricks_" tag "_" platforms[i] ext;if(!(name in names) || !((name ".sha256") in names)) complete=0}
  if(!complete) continue
  name="hyperbricks_" tag "_" platform ".tar.gz"
  if(best=="" || compare(tag,best)>0){best=tag;besthash=names[name];sidehash=names[name ".sha256"]}
 }
 if(best=="") {print "No complete published HyperBricks release found" > "/dev/stderr";exit 1}
 print best, besthash, sidehash
}
HB_RELEASES_AWK
 api=https://api.github.com/repos/hyperbricks/hyperbricks-builder
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
 base="https://github.com/hyperbricks/hyperbricks-builder/releases/download/$tag"
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
