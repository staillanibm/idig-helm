#!/usr/bin/env bash
# Apply or check the CRDs the IDIG chart depends on. CRDs are cluster-scoped and
# may be shared with other installs (e.g. API Connect in another namespace), so
# they are managed here, not by the Helm chart.
#
# Usage:
#   scripts/crds.sh check [k8s|ocp]   Read-only: compare crds/*.yaml with the cluster
#   scripts/crds.sh apply [k8s|ocp]   check, then server-side apply + wait Established
#
# Environment:
#   CRDS_DIR      directory holding the CRD files (default: <repo>/crds)
#   FORCE=1       apply even when check finds incompatible differences
#   APPLY_APIC=1  also apply apic.yaml when the APIC CRDs already exist on the cluster
#
# check classifies each CRD (descriptions ignored):
#   new         not on the cluster
#   identical   same schema
#   additive    bundle only adds fields/enum values -> safe to apply
#   changed     same fields, different values (review before applying)
#   INCOMPAT    a version or field of the cluster CRD is missing in the bundle
set -euo pipefail

CMD=${1:-}
PLATFORM=${2:-ocp}
CRDS_DIR=${CRDS_DIR:-"$(cd "$(dirname "$0")/.." && pwd)/crds"}
KUBECTL=${KUBECTL:-kubectl}

case "$CMD" in check|apply) ;; *) echo "usage: $0 check|apply [k8s|ocp]" >&2; exit 2 ;; esac
case "$PLATFORM" in k8s|ocp) ;; *) echo "PLATFORM must be k8s or ocp" >&2; exit 2 ;; esac
for t in yq jq "$KUBECTL"; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 2; }; done

# Flattens a CRD's versions to "version<TAB>path<TAB>value" lines, ignoring descriptions.
FLATTEN='
  [.spec.versions[] | . as $v | ($v.schema // {}) | tostream
    | select(length == 2)
    | select((.[0][-1] != "description") or (.[0][-2] == "properties"))
    | "\($v.name)\t\(.[0] | map(tostring) | join("/"))\t\(.[1] | tostring)"] | sort | .[]'

cluster_json=$(mktemp); trap 'rm -rf "$cluster_json" "${tmp:-}"' EXIT
"$KUBECTL" get crd -o json > "$cluster_json"
tmp=$(mktemp -d)

# check_file FILE -> prints one line per CRD, returns 1 if any INCOMPAT
check_file() {
  local file=$1 rc=0 name status
  yq ea -o=json -I0 '[.] | .[] | select(.kind == "CustomResourceDefinition")' "$file" > "$tmp/bundle.ndjson"
  while IFS= read -r crd; do
    name=$(jq -r '.metadata.name' <<<"$crd")
    if ! jq -e --arg n "$name" '.items[] | select(.metadata.name == $n)' "$cluster_json" >"$tmp/live.json" 2>/dev/null; then
      printf '  %-10s %s\n' new "$name"; continue
    fi
    jq -r "$FLATTEN" <<<"$crd" > "$tmp/b.txt"
    jq -r "$FLATTEN" "$tmp/live.json" > "$tmp/c.txt"
    local missing_versions
    missing_versions=$(jq -r --argjson b "$crd" '[.spec.versions[].name] - [$b.spec.versions[].name] | join(",")' "$tmp/live.json")
    # Lines only in cluster / only in bundle, keyed by "version<TAB>path".
    cut -f1,2 "$tmp/c.txt" | sort -u > "$tmp/c.keys"; cut -f1,2 "$tmp/b.txt" | sort -u > "$tmp/b.keys"
    local only_cluster only_bundle changed
    only_cluster=$(comm -23 "$tmp/c.keys" "$tmp/b.keys" | wc -l | tr -d ' ')
    only_bundle=$(comm -13 "$tmp/c.keys" "$tmp/b.keys" | wc -l | tr -d ' ')
    changed=$(awk -F'\t' 'NR==FNR{c[$1 "\t" $2]=$3; next} {k=$1 "\t" $2; if ((k in c) && c[k]!=$3) n++} END{print n+0}' "$tmp/c.txt" "$tmp/b.txt")
    if [ -n "$missing_versions" ] || [ "$only_cluster" -gt 0 ]; then
      status=INCOMPAT; rc=1
      printf '  %-10s %s (cluster-only fields: %s, missing versions: %s)\n' "$status" "$name" "$only_cluster" "${missing_versions:-none}"
    elif [ "$changed" -gt 0 ]; then
      printf '  %-10s %s (%s changed value(s), %s added field(s))\n' changed "$name" "$changed" "$only_bundle"
    elif [ "$only_bundle" -gt 0 ]; then
      printf '  %-10s %s (%s added field(s))\n' additive "$name" "$only_bundle"
    else
      printf '  %-10s %s\n' identical "$name"
    fi
  done < "$tmp/bundle.ndjson"
  return $rc
}

crd_exists() { jq -e --arg n "$1" '.items[] | select(.metadata.name == $n)' "$cluster_json" >/dev/null; }

files=(idig-operator nanogateway valkey)
apic_present=false; crd_exists apiconnectclusters.apiconnect.ibm.com && apic_present=true
files+=(apic)
gateway_api=false
if [ "$PLATFORM" = k8s ] && ! crd_exists gateways.gateway.networking.k8s.io; then gateway_api=true; files+=(gateway-api); fi

incompat=0; to_apply=()
for f in "${files[@]}"; do
  echo "== crds/$f.yaml"
  check_file "$CRDS_DIR/$f.yaml" || incompat=1
  if [ "$f" = apic ] && $apic_present && [ "${APPLY_APIC:-0}" != 1 ]; then
    echo "  (APIC CRDs already on the cluster -- owned by their installer, not applied; APPLY_APIC=1 to force)"
    continue
  fi
  to_apply+=("$f")
done
[ "$PLATFORM" = ocp ] && echo "== gateway-api: skipped (OpenShift manages the Gateway API CRDs)"
[ "$PLATFORM" = k8s ] && ! $gateway_api && echo "== gateway-api: skipped (CRDs already on the cluster)"

[ "$CMD" = check ] && exit $incompat
if [ "$incompat" = 1 ] && [ "${FORCE:-0}" != 1 ]; then
  echo "✗ Incompatible CRD differences found -- review above, or FORCE=1 to apply anyway." >&2; exit 1
fi

for f in "${to_apply[@]}"; do
  echo "▶ apply crds/$f.yaml"
  "$KUBECTL" apply --server-side --force-conflicts -f "$CRDS_DIR/$f.yaml"
  yq ea '[.] | .[] | select(.kind == "CustomResourceDefinition") | .metadata.name' "$CRDS_DIR/$f.yaml" \
    | xargs -I{} "$KUBECTL" wait --for=condition=Established --timeout=60s crd/{} >/dev/null
done
echo "✓ CRDs applied and Established."
