#!/usr/bin/env bash
# Build the newest version tag reachable from upstream main.
set -euo pipefail

BUILDER_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_URL=https://github.com/hyperbricks/hyperbricks.git

for command in git go; do
  command -v "$command" >/dev/null || { printf 'Required command missing: %s\n' "$command" >&2; exit 1; }
done
if command -v sha256sum >/dev/null; then
  HASH_COMMAND=sha256sum
elif command -v shasum >/dev/null; then
  HASH_COMMAND=shasum
else
  printf 'Install sha256sum or shasum first.\n' >&2
  exit 1
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hyperbricks-build.XXXXXX")"
STAGING_DIR=
cleanup() {
  rm -rf -- "$WORK_DIR"
  if [[ -n "$STAGING_DIR" ]]; then rm -rf -- "$STAGING_DIR"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf 'Fetching upstream main and tags…\n'
git clone --quiet --single-branch --branch main --no-tags "$SOURCE_URL" "$WORK_DIR/source"
git -C "$WORK_DIR/source" fetch --quiet origin '+refs/tags/*:refs/tags/*'

TAG="$(bash "$BUILDER_DIR/scripts/latest-tag.sh" "$WORK_DIR/source")"
COMMIT="$(git -C "$WORK_DIR/source" rev-parse "refs/tags/${TAG}^{commit}")"
git -C "$WORK_DIR/source" checkout --quiet --detach "$COMMIT"
printf 'Building %s (%s)\n' "$TAG" "$COMMIT"

OUTPUT_DIR="$BUILDER_DIR/dist/$TAG"
[[ ! -e "$OUTPUT_DIR" ]] || { printf 'Output already exists: %s\nMove it aside before rebuilding.\n' "$OUTPUT_DIR" >&2; exit 1; }
mkdir -p "$BUILDER_DIR/dist"
STAGING_DIR="$(mktemp -d "$BUILDER_DIR/dist/.build.XXXXXX")"

cd "$WORK_DIR/source"
go mod download
go mod verify
FAILED_TARGETS=
for target in darwin/amd64 darwin/arm64 linux/amd64 linux/arm64 windows/amd64; do
  target_os="${target%/*}"
  target_arch="${target#*/}"
  filename="hyperbricks_${TAG}_${target_os}_${target_arch}"
  if [[ "$target_os" == windows ]]; then filename="$filename.exe"; fi
  printf 'Building %s…\n' "$target"
  if ! CGO_ENABLED=0 GOOS="$target_os" GOARCH="$target_arch" \
    go build -mod=readonly -trimpath -buildvcs=true -o "$STAGING_DIR/$filename" ./cmd/hyperbricks; then
    rm -f -- "$STAGING_DIR/$filename"
    FAILED_TARGETS="${FAILED_TARGETS}${target} "
  fi
done

{
  printf 'repository=%s\ntag=%s\ncommit=%s\n' "$SOURCE_URL" "$TAG" "$COMMIT"
  go version
  printf 'CGO_ENABLED=0\n'
} > "$STAGING_DIR/SOURCE.txt"
(
  cd "$STAGING_DIR"
  shopt -s nullglob
  binaries=(hyperbricks_*)
  if [[ ${#binaries[@]} -eq 0 ]]; then
    : > SHA256SUMS
  elif [[ "$HASH_COMMAND" == sha256sum ]]; then
    sha256sum hyperbricks_* > SHA256SUMS
  else
    shasum -a 256 hyperbricks_* > SHA256SUMS
  fi
)
if [[ -n "$FAILED_TARGETS" ]]; then
  printf 'Build incomplete. Failed targets: %s\n' "$FAILED_TARGETS" > "$STAGING_DIR/BUILD_FAILED.txt"
fi
mv -- "$STAGING_DIR" "$OUTPUT_DIR"
STAGING_DIR=
if [[ -n "$FAILED_TARGETS" ]]; then
  printf 'Build incomplete. Failed targets: %s\nSuccessful binaries: %s\n' "$FAILED_TARGETS" "$OUTPUT_DIR" >&2
  exit 1
fi
printf 'Build complete: %s\n' "$OUTPUT_DIR"
