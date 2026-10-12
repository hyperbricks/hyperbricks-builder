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

## Verified installers and release publication

`installers/install.sh` (macOS/Linux) and `installers/install.ps1` (Windows amd64)
install to a user directory without administrator privileges or profile edits.
By default they choose the highest complete published version, including beta
versions, from the paginated product release list. Use `--version vX.Y.Z-beta`
or PowerShell `-Version vX.Y.Z-beta` to select one exact published tag. There is
no fallback when that tag or its platform package is missing.

Both installers validate SHA-256 against the release checksum file **and** the
asset digest returned by GitHub's HTTPS API before extracting or executing the
binary. They accept only the expected single regular archive member and verify
the executable's embedded version before atomically replacing the installation.
Failed downloads or verification preserve the previous executable. Download
redirects are followed individually and only to HTTPS GitHub/asset hosts;
API redirects are refused. There is no TLS/hash bypass option.

SHA-256 establishes integrity against the trusted GitHub metadata, not an
independent author signature. The install-script checksum must itself come from
the trusted, commit-pinned GitHub source before executing a website copy. The
website script URL must respond directly; a redirect is not accepted.

The shell installer is generated from `install.template.sh` and `releases.awk`:
run `python3 scripts/build-installers.py` after editing them or `install.ps1`.
CI checks generated bytes and checksum files. Native installer fixtures test
actual execution and safe replacement; the Windows product job also tests its
freshly built executable through the installer. Windows process/cache tests run
five times per job, and a failure in any repetition fails the job.

For release publication, manually run **Build latest HyperBricks tag** on builder
`main`, leave `source_ref` empty and enable **publish**. All five native builds,
the product tests (five repetitions on Windows), and all five native installer
jobs must succeed before publication. Push and pull-request runs never publish.

Publication uploads the verified packages, installer scripts and SHA-256 files
to a draft release in **hyperbricks/hyperbricks-builder**. Its version tag points
to the builder commit used by the workflow. Release metadata records the exact
product tag and source commit; the product repository is only read, never
modified. Uploaded digests are verified before the draft becomes public.
Published releases and assets are never overwritten. An interrupted upload can
resume only when the draft's source and existing asset hashes match.

Only the publication job receives `contents: write`, using the builder's own
`GITHUB_TOKEN`. No additional token or product-repository credentials are needed.
The installers discover and download releases from **hyperbricks-builder**.
Website distribution still requires copying the tested installers to the site
and checking an installation against the published download assets.
