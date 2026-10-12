# HyperBricks Builder

Run from macOS or Linux with Bash, Git and Go installed:

```sh
./build.sh
```

The script fetches `hyperbricks/hyperbricks`, selects the highest version tag
reachable from upstream `main` (including beta tags), checks out that exact
commit in a temporary directory, and builds:

- macOS: amd64 and arm64
- Linux: amd64 and arm64
- Windows: amd64

Outputs are uncompressed executables in `dist/<tag>/`, alongside `SHA256SUMS`
and `SOURCE.txt` with the source commit and Go version. Existing output is never
overwritten. If a platform build fails, successful binaries are retained,
`BUILD_FAILED.txt` lists the failed targets, and the script exits with status 1.

Go may download the toolchain required by the source's `go.mod`. Builds use
`CGO_ENABLED=0` for cross-compilation without separate native toolchains. These
binaries do not support loading native Go plugins. macOS/Windows signing is
not included. Compilation alone does not establish runtime compatibility on
all target systems.

The script only fetches and builds. It does not change the product checkout,
create tags, publish releases or configure CI.
