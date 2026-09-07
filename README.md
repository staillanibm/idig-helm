# idig-helm

Helm chart repo for deploying IBM DataPower Interact Gateway (IDIG)
on Kubernetes/OpenShift.

**The chart itself, its installation instructions, prerequisites, values
reference, and per-wave verification steps live in
[`charts/idig/README.md`](charts/idig/README.md) — start there.**

## Repo layout

- `charts/idig/` — the chart. See its own README for everything
  deployment-related.
- `scripts/mirror-images.sh` — standalone tool to mirror IDIG product
  images into a target registry; not part of the chart, not gated by any
  Helm wave. See below for how to get the inputs it needs and how to run
  it.

## Getting the product images and signatures

IDIG's product images ship inside a single tool image, not as separate
per-image downloads. From **IBM Fix Central**, download for the IDIG
version you're deploying:

- `idig-image-tool_<version>.tar.gz` — a container image that already
  bakes in every IDIG product image (this is why the tarball is
  multi-gigabyte). It does not pull from any external source registry at
  upload time.
- `signatures_<version>.zip` (or the equivalent unpacked directory) — the
  detached GPG signature for that tarball plus IBM's public key
  (`*key.pub.asc`).

**Download the `.tar.gz` as-is — do not let your browser auto-expand
it.** Safari's "Open safe files after downloading" does this silently;
turn it off first (General → uncheck that option). A re-packed/re-gzipped
archive can never match the vendor's GPG signature, since gzip
recompression isn't byte-reproducible.

Save both under `binaries/` (git-ignored), e.g.:

```
binaries/idig-image-tool_12.1.1.2.tar.gz
binaries/signatures_12.1.1.2.zip
```

`idig-operator-release-files_*/` (also git-ignored) is the separate
`release_files.zip` bundle from the same Fix Central release — the vendor
manifests this chart's templates are adapted from.

### Verifying the release bundle's integrity

Separately from `mirror-images.sh`'s verification of the image-tool
tarball below, IBM also lets you verify the release bundle itself
(`idig-operator-release-files_<version>.zip` and any other file from the
same release, e.g. `helper_files.zip`) via GPG:

1. Download the **DataPower Interact Gateway Security Signature Bundle
   File** for your version from Fix Central — a separate download from
   the release bundle itself, named `signatures_<version>.zip`.
2. Extract it into the **same folder** as the file(s) you want to verify —
   this drops one `<file>.asc` per file next to it.
3. Import IBM's public key once (create `PRD0003216key.pub.gpg` with the
   PGP block IBM's docs provide, then `gpg --import PRD0003216key.pub.gpg`).
   Confirm the fingerprint matches `39ED 1634 5FCD EDB5 D6ED E860 020E D6B5
   DBE6 5F3B` via `gpg --list-key --fingerprint idig`.
4. Verify each file — no second argument, `gpg` finds the signed file by
   the `.asc` naming convention:
   ```bash
   gpg --verify idig-operator-release-files_<version>.zip.asc
   ```

## Mirroring images with `scripts/mirror-images.sh`

The script verifies the tarball's integrity (checksums on the signature
file, then the GPG signature itself against IBM's public key) and, only
if that passes, loads the image and runs it to push the full IDIG image
set into your target registry. It fails closed — any checksum mismatch
or a non-`GOODSIG` GPG result aborts before touching Docker/Podman.

```bash
IMAGE_TOOL_TARBALL=binaries/idig-image-tool_12.1.1.2.tar.gz \
SIGNATURES_DIR=binaries/signatures_12.1.1.2.zip \
TARGET_REGISTRY=myregistry.example.com/idig \
REGISTRY_USER=my-registry-username \
REGISTRY_PASSWORD=my-registry-password-or-token \
./scripts/mirror-images.sh
```

For an OpenShift internal registry, `REGISTRY_USER` can be any string
(e.g. `unused`) and `REGISTRY_PASSWORD` is an `oc whoami -t` token — pipe
it in, never paste it into a command whose output gets displayed.

Optional env vars: `CONTAINER_ENGINE` (`docker`/`podman`, auto-detected
otherwise), `SKIP_UPLOAD=1` (verify + load only, useful to just check
integrity or inspect `image-tool version --images`), `GNUPGHOME` (use a
dedicated GPG homedir instead of a throwaway temp one).

Once it finishes, point the chart's `global.imageRegistry` value (see
[`charts/idig/README.md`](charts/idig/README.md)) at `TARGET_REGISTRY`.

This script is standalone tooling — it's never invoked from, or gated
by, the chart's `deployment.wave`, and re-running it is safe (re-run it
whenever you pick up a new IDIG release).

## Orchestrating with `Makefile`

The chart works driven directly with `helm`/`kubectl`/`oc`, exactly as
documented in `charts/idig/README.md`. `Makefile` at the repo root wraps
that same sequence of steps — prerequisites, secrets, and all 4 chart
waves — so a full deployment is one command instead of the manual
walkthrough:

```bash
cp .env.example .env && $EDITOR .env   # registry, entitlement key, WatsonX creds -- see .env.example
make deploy PLATFORM=k8s               # or PLATFORM=ocp
```

`PLATFORM` (`k8s` or `ocp`) is required for any target that touches
platform-specific prerequisites or values — the Makefile never guesses
it. `NAMESPACE` (default `idig`) and `VALUES_FILE` (default
`charts/idig/examples/values-dev.yaml`) can be overridden the same way.

Targets, in the order `deploy` runs them:

- **`make fill-values PLATFORM=k8s|ocp [DOMAIN=...]`** — fills
  `global.imageRegistry` (from `.env`'s `REGISTRY_SERVER`) and
  `global.domain` into `VALUES_FILE` in place, and sets
  `envoyGateway.enabled` to match the platform. `DOMAIN` is
  auto-detected on OpenShift (`oc get ingresses.config/cluster`) if
  unset; on Kubernetes it must be passed explicitly.
- **`make check-values PLATFORM=k8s|ocp`** — verifies `VALUES_FILE` has
  `imageRegistry`/`domain`/`license.accept` set and
  `envoyGateway.enabled` consistent with `PLATFORM`, without changing
  anything. What `deploy` runs before touching the cluster.
- **`make prereqs PLATFORM=k8s|ocp`** — installs/configures everything
  `charts/idig/README.md`'s "Prerequisites" section lists as external to
  the chart. Dispatches to `prereqs-k8s` (`cert-manager-k8s`,
  `envoy-gateway-install`, `envoy-gateway-enable-backend`) or
  `prereqs-ocp` (`cert-manager-ocp`, `wildcard-routes`); each step is
  also runnable on its own.
- **`make secrets`** — creates the namespace plus the registry pull
  secret, entitlement-key secret, and (if set in `.env`) the WatsonX
  credentials secret. Also runnable as `registry-secret`,
  `entitlement-key-secret`, `watsonx-secret`, `namespace` individually.
- **`make wave0` / `wave1` / `wave2` / `wave3`** — one chart wave each
  (PKI; operators; Valkey; the IDIG cluster CR), matching
  `deployment.wave` in the chart. Useful to re-run a single wave after a
  values change instead of the whole `deploy`.
- **`make deploy PLATFORM=k8s|ocp`** — `check-values` + `prereqs` +
  `secrets` + `wave0`...`wave3`, in order. The one-shot install.
- **`make upgrade`** — re-applies `wave1` and `wave3` only (see
  `charts/idig/README.md` "Upgrading" for when/why that's the right
  scope for an upgrade, not a full `deploy`).
- **`make uninstall`** — `helm uninstall` of all 4 releases
  (`idig-cluster`, `idig-valkey`, `idig-operators`, `idig-prereqs`), in
  reverse install order. Does not delete the namespace or cert-manager
  Issuers/Certificates.
- **`make info PLATFORM=k8s|ocp`** — prints the IDIG console and
  Developer Portal URLs (from the platform's Route/HTTPRoute objects)
  and their `administrator` admin passwords (from the
  `<cr-name>-idig-admin-pass` / `<cr-name>-devportal-admin-secret`
  secrets), so you don't have to look them up by hand after a deploy.

Run `make help` any time for this same list with current variable
values filled in.
