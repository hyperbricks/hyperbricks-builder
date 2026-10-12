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

## GitHub Actions

The **Build latest HyperBricks tag** workflow runs on pushes to this repository's
`main`, on pull requests, and manually via **Actions → Build latest HyperBricks
tag → Run workflow**. By default, each run selects the newest version tag reachable from
upstream `main`, including betas, once and pins every job to its exact commit.
The local script and CI share the same tag selector.

The five targets above build on native GitHub-hosted runners. CI uses the Go
version from the selected source's `go.mod`, verifies the executable's version,
and runs process lifecycle and response-cache tests on each platform. The
Windows runner additionally executes the process-tree termination test. The
workflow requires explicit passing results for the critical tests; a missing
or skipped Windows test cannot make the run green.

Download each successful platform's archive, SHA-256 sidecar and source metadata
from the workflow run's **Artifacts** section. Unix builds use `.tar.gz` to
preserve executable permissions; Windows uses `.zip`. Test output is retained
on success or failure. Artifacts expire after 14 days. All five jobs must pass
for a successful workflow; individual platform artifacts may exist during a
failed run.

No extra secrets, product-repository changes or release publication are involved.
A new product tag does not itself trigger this separate repository: use **Run
workflow** to build the latest tag. Native Go plugins remain disabled, matching
the local script's `CGO_ENABLED=0` build policy.

### Test a branch or commit before tagging

Open **Actions → Build latest HyperBricks tag → Run workflow**. Keep the workflow
branch set to `main` (this builder repository), and enter the HyperBricks branch
(e.g. `release/v1.3.2-beta`) or full commit SHA in **source_ref**. Leave this field
empty for the normal latest-tag build.

A supplied ref is resolved once to its exact commit in `hyperbricks/hyperbricks`.
All five runners build and test that same commit, even if the branch moves during
the run. The binary version is checked against that commit's `assets/version.md`;
a release tag is not required. Invalid refs fail checkout without falling back.
These test runs retain test output but do not create download packages or tags.
The resolved commit and selection mode appear in the run summary.
