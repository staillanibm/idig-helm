#!/usr/bin/env bash
# Verify the integrity of the IBM idig-image-tool release artifact and, if
# and only if verification succeeds, load it and run it to mirror all IDIG
# product images into a target container registry.
#
# This script does NOT template anything and is not part of the Helm chart:
# it is a one-off (re-run per release) prerequisite step, matching
# README.md -> "Downloading Release Build Files" (idig-operator-release-files_12).
#
# Usage:
#   IMAGE_TOOL_TARBALL=/path/to/idig-image-tool_12.1.1.0.tar.gz \
#   SIGNATURES_DIR=/path/to/signatures_12 \
#   TARGET_REGISTRY=my-registry.example.com/my-path \
#   REGISTRY_USER=my-registry-username \
#   REGISTRY_PASSWORD=my-registry-password-or-token \
#   ./scripts/mirror-images.sh
#
# Note: image-tool ships with ALL IDIG product images already baked in (that's
# why the tarball is multi-gigabyte) -- it does not pull from any external/
# source registry (e.g. IBM Artifactory) at upload time. `upload` takes a
# single username/password pair, which authenticates to TARGET_REGISTRY only
# (confirmed via `image-tool upload --help`: only one --username/--password,
# for the destination REGISTRY positional arg). There is no public IBM
# Artifactory and none is needed here.
#
# Required environment variables:
#   IMAGE_TOOL_TARBALL   Path to the idig-image-tool_<version>.tar.gz as
#                         downloaded from IBM (must NOT be pre-extracted --
#                         browsers that auto-expand downloads, e.g. Safari's
#                         "Open safe files after downloading", will corrupt
#                         the archive for signature purposes; disable that
#                         setting before downloading).
#   SIGNATURES_DIR        Path to the signatures directory OR to a
#                         signatures_<version>.zip archive, containing the
#                         detached GPG signature (*.asc) and the IBM public
#                         key (PRD0003216key.pub.asc). If a .zip is given, it
#                         is extracted to a temp dir first.
#
#                         Note on the *.asc.md5 / *.asc.sha1 / *.asc.sha256
#                         files IBM ships alongside the signature: despite
#                         the naming, these are checksums OF THE .asc
#                         SIGNATURE FILE ITSELF (verified empirically -- e.g.
#                         `shasum -a 256 foo.tar.gz.asc` equals the content of
#                         `foo.tar.gz.asc.sha256`), not of the tarball. They
#                         only guard against a corrupted/truncated signature
#                         download, not tarball integrity -- that's what the
#                         GPG signature verification (against the tarball) is
#                         for. This script checks both: the tarball's actual
#                         integrity/authenticity comes from the GPG
#                         signature; the checksums just sanity-check the
#                         signature file transferred correctly.
#   TARGET_REGISTRY        Registry (+ optional path) to upload images to,
#                         e.g. myregistry.example.com/idig
#   REGISTRY_USER          Username for TARGET_REGISTRY (e.g. "unused" for an
#                         OpenShift internal registry login via token, or any
#                         username your registry expects).
#   REGISTRY_PASSWORD      Password/token for TARGET_REGISTRY (e.g. the
#                         output of `oc whoami -t` for an OpenShift internal
#                         registry). Log in with your engine beforehand if
#                         your registry needs it for anything beyond this
#                         push (e.g. `oc whoami -t | podman login <registry>
#                         --username unused --password-stdin`).
#
# Optional environment variables:
#   CONTAINER_ENGINE      "docker" or "podman" (default: auto-detect). Auto-detect
#                         tries docker first, then podman, but only accepts an
#                         engine that both exists in PATH AND responds to a
#                         live health check (`<engine> version`) -- a present-
#                         but-broken `docker` CLI (e.g. pointed at an
#                         incompatible/stale DOCKER_HOST socket, which is a
#                         real failure mode when both Docker Desktop/Colima
#                         and Podman are installed side by side) is skipped
#                         in favor of a working podman, rather than being
#                         used and failing confusingly mid-script. Set this
#                         explicitly to force one engine and get a clear
#                         error instead of silent fallback.
#   GNUPGHOME              Dedicated GPG homedir used to import the IBM key
#                         into, so this script never touches the caller's
#                         real GPG keyring (default: a temp dir, cleaned up
#                         on exit).
#   SKIP_UPLOAD             If set to "1", stop after verification + load,
#                         without running the upload (useful to just check
#                         integrity, or to inspect `image-tool version --images`).

set -euo pipefail

log()  { printf '[mirror-images] %s\n' "$*" >&2; }
die()  { log "ERROR: $*"; exit 1; }

: "${IMAGE_TOOL_TARBALL:?Set IMAGE_TOOL_TARBALL to the path of idig-image-tool_<version>.tar.gz}"
: "${SIGNATURES_DIR:?Set SIGNATURES_DIR to the path of the signatures_12 directory}"

[[ "$IMAGE_TOOL_TARBALL" == *.tar.gz ]] || die \
  "IMAGE_TOOL_TARBALL must be the original .tar.gz artifact (got: $IMAGE_TOOL_TARBALL). \
A pre-extracted .tar cannot be verified against the GPG signature / checksums \
(gzip re-compression is not byte-for-byte reproducible). Re-download the .tar.gz \
without letting the browser auto-expand it."

[[ -f "$IMAGE_TOOL_TARBALL" ]] || die "File not found: $IMAGE_TOOL_TARBALL"

signatures_extract_dir=""
if [[ -f "$SIGNATURES_DIR" && "$SIGNATURES_DIR" == *.zip ]]; then
  command -v unzip >/dev/null 2>&1 || die "unzip is required to extract $SIGNATURES_DIR but was not found in PATH"
  signatures_extract_dir="$(mktemp -d)"
  log "Extracting signatures archive ${SIGNATURES_DIR} ..."
  unzip -q -o "$SIGNATURES_DIR" -d "$signatures_extract_dir"
  SIGNATURES_DIR="$signatures_extract_dir"
elif [[ ! -d "$SIGNATURES_DIR" ]]; then
  die "SIGNATURES_DIR must be a directory or a .zip archive: $SIGNATURES_DIR"
fi

tarball_name="$(basename "$IMAGE_TOOL_TARBALL")"
sig_file="${SIGNATURES_DIR}/${tarball_name}.asc"
md5_file="${sig_file}.md5"
sha1_file="${sig_file}.sha1"
sha256_file="${sig_file}.sha256"
pubkey_file="$(find "$SIGNATURES_DIR" -maxdepth 1 -name '*key.pub.asc' | head -1)"

for f in "$sig_file" "$md5_file" "$sha1_file" "$sha256_file"; do
  [[ -f "$f" ]] || die "Expected signature/checksum file not found: $f"
done
[[ -n "$pubkey_file" && -f "$pubkey_file" ]] || die \
  "No IBM public key (*key.pub.asc) found in $SIGNATURES_DIR"

command -v gpg >/dev/null 2>&1 || die "gpg is required but not found in PATH"

sha256_tool=""
for candidate in "sha256sum" "shasum"; do
  if command -v "$candidate" >/dev/null 2>&1; then sha256_tool="$candidate"; break; fi
done
[[ -n "$sha256_tool" ]] || die "Need sha256sum or shasum in PATH"

md5_tool=""
for candidate in "md5sum" "md5"; do
  if command -v "$candidate" >/dev/null 2>&1; then md5_tool="$candidate"; break; fi
done
[[ -n "$md5_tool" ]] || die "Need md5sum or md5 in PATH"

sha1_tool=""
for candidate in "sha1sum" "shasum"; do
  if command -v "$candidate" >/dev/null 2>&1; then sha1_tool="$candidate"; break; fi
done
[[ -n "$sha1_tool" ]] || die "Need sha1sum or shasum in PATH"

compute_sha256() {
  if [[ "$sha256_tool" == "shasum" ]]; then shasum -a 256 "$1" | awk '{print $1}'
  else sha256sum "$1" | awk '{print $1}'; fi
}
compute_sha1() {
  if [[ "$sha1_tool" == "shasum" ]]; then shasum -a 1 "$1" | awk '{print $1}'
  else sha1sum "$1" | awk '{print $1}'; fi
}
compute_md5() {
  if [[ "$md5_tool" == "md5" ]]; then md5 -q "$1"
  else md5sum "$1" | awk '{print $1}'; fi
}

gnupg_home="${GNUPGHOME:-}"
cleanup_gnupg_home=0
if [[ -z "$gnupg_home" ]]; then
  gnupg_home="$(mktemp -d)"
  cleanup_gnupg_home=1
fi
cleanup() {
  [[ "$cleanup_gnupg_home" == "1" ]] && rm -rf "$gnupg_home"
  [[ -n "$signatures_extract_dir" ]] && rm -rf "$signatures_extract_dir"
}
trap cleanup EXIT

log "Verifying checksums of the signature file (${tarball_name}.asc) ..."

expected_sha256="$(tr -d ' \t\r\n' < "$sha256_file")"
actual_sha256="$(compute_sha256 "$sig_file")"
[[ "$expected_sha256" == "$actual_sha256" ]] || die \
  "SHA256 mismatch on signature file ${sig_file}. expected=${expected_sha256} actual=${actual_sha256}"
log "SHA256 OK"

expected_sha1="$(tr -d ' \t\r\n' < "$sha1_file")"
actual_sha1="$(compute_sha1 "$sig_file")"
[[ "$expected_sha1" == "$actual_sha1" ]] || die \
  "SHA1 mismatch on signature file ${sig_file}. expected=${expected_sha1} actual=${actual_sha1}"
log "SHA1 OK"

expected_md5="$(tr -d ' \t\r\n' < "$md5_file")"
actual_md5="$(compute_md5 "$sig_file")"
[[ "$expected_md5" == "$actual_md5" ]] || die \
  "MD5 mismatch on signature file ${sig_file}. expected=${expected_md5} actual=${actual_md5}"
log "MD5 OK"

log "Verifying GPG signature of ${tarball_name} against IBM public key (${pubkey_file}) ..."
GNUPGHOME="$gnupg_home" gpg --batch --quiet --import "$pubkey_file" 2>&1 | while read -r line; do log "gpg: $line"; done

gpg_status_file="$(mktemp)"
GNUPGHOME="$gnupg_home" gpg --batch --status-file "$gpg_status_file" --verify "$sig_file" "$IMAGE_TOOL_TARBALL" 2>&1 \
  | while read -r line; do log "gpg: $line"; done
gpg_status="$(cat "$gpg_status_file")"
rm -f "$gpg_status_file"

if ! grep -q '^\[GNUPG:\] GOODSIG' <<<"$gpg_status"; then
  die "GPG signature verification FAILED for ${tarball_name}. Do not proceed -- \
the artifact may be corrupted or tampered with."
fi
log "GPG signature OK (GOODSIG)"

log "Integrity verification passed for ${tarball_name}."

# -----------------------------------------------------------------------------
# Load and run the image-tool container
# -----------------------------------------------------------------------------

engine_is_healthy() {
  # `images` (not just `command -v`, and not just `version`) is the check
  # that actually matches the failure mode seen in practice: a `docker` CLI
  # pointed (via DOCKER_HOST) at a Podman socket can pass `docker version`
  # AND `docker info` cleanly while still failing on `docker images` with an
  # API-version-mismatch error -- `version`/`info` alone would NOT have
  # caught it. `images` is a fast, read-only, real API call closest to the
  # `load`/`run` calls this script actually needs to succeed.
  "$1" images >/dev/null 2>&1
}

engine="${CONTAINER_ENGINE:-}"
if [[ -n "$engine" ]]; then
  case "$engine" in
    docker|podman) ;;
    *) die "CONTAINER_ENGINE must be 'docker' or 'podman', got: $engine" ;;
  esac
  command -v "$engine" >/dev/null 2>&1 || die "CONTAINER_ENGINE=$engine but '$engine' is not in PATH"
  engine_is_healthy "$engine" || die \
    "CONTAINER_ENGINE=$engine but '$engine images' failed -- daemon/socket unreachable or CLI/daemon API mismatch."
else
  for candidate in docker podman; do
    if command -v "$candidate" >/dev/null 2>&1 && engine_is_healthy "$candidate"; then
      engine="$candidate"
      break
    fi
  done
  [[ -n "$engine" ]] || die \
    "Need a working docker or podman in PATH (found binaries but none responded to '<engine> images'; \
or neither is installed). Set CONTAINER_ENGINE explicitly to force one and see its error."
fi
log "Using container engine: $engine"

log "Loading ${tarball_name} into ${engine} ..."
load_output="$("$engine" load < "$IMAGE_TOOL_TARBALL")"
echo "$load_output" >&2

# image-tool's own tar tags itself as "idig-image-tool-<version>:latest"
# (confirmed via OCI manifest inspection); extract the actual tag docker/podman
# reports rather than hardcoding a version.
loaded_image="$(printf '%s\n' "$load_output" | sed -n 's/^Loaded image: //p' | tail -1)"
[[ -n "$loaded_image" ]] || die \
  "Could not determine loaded image name/tag from ${engine} load output above."
log "Loaded image: ${loaded_image}"

if [[ "${SKIP_UPLOAD:-0}" == "1" ]]; then
  log "SKIP_UPLOAD=1 set, stopping after load. Loaded image: ${loaded_image}"
  exit 0
fi

: "${TARGET_REGISTRY:?Set TARGET_REGISTRY to the destination registry/path (e.g. myregistry.example.com/idig)}"
: "${REGISTRY_USER:?Set REGISTRY_USER to the TARGET_REGISTRY username}"
: "${REGISTRY_PASSWORD:?Set REGISTRY_PASSWORD to the TARGET_REGISTRY password/token}"

log "Uploading images to ${TARGET_REGISTRY} (this bakes in the full IDIG image set, expect it to take a while) ..."
"$engine" run --rm "$loaded_image" --accept-license upload \
  "$TARGET_REGISTRY" \
  --username "$REGISTRY_USER" \
  --password "$REGISTRY_PASSWORD"

log "Listing images image-tool expects to have uploaded ..."
"$engine" run --rm "$loaded_image" --accept-license version --images

log "Done. Point Helm's global.imageRegistry value at: ${TARGET_REGISTRY}"
