#!/usr/bin/env bash
# Read-only checks before installing the chart on a cluster that may already host
# another install of the same operators (typically API Connect in another namespace).
# Nothing is created, changed or deleted.
#
# Usage: scripts/preflight.sh <k8s|ocp> <namespace> <values-file>
#   KUBECTL=oc    CLI to use (default: kubectl)
#
# Checks:
#   1. CRDs         scripts/crds.sh check
#   2. Names        cluster-scoped objects this chart would create vs what exists
#   3. Operators    Valkey / nano operators of OTHER namespaces: are they restricted?
#   4. API Connect  ibm-apiconnect operator versions already installed (OLM)
# Exit code 1 if a blocking problem is found (name collision, incompatible CRD).
set -uo pipefail

PLATFORM=${1:?usage: $0 <k8s|ocp> <namespace> <values-file>}
NS=${2:?}
VALUES=${3:?}
KUBECTL=${KUBECTL:-kubectl}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
bad=0; warn=0
ok()   { printf '  ✓ %s\n' "$*"; }
fail() { printf '  ✗ %s\n' "$*"; bad=1; }
note() { printf '  ⚠ %s\n' "$*"; warn=1; }

echo "== 1. CRDs"
KUBECTL=$KUBECTL "$ROOT/scripts/crds.sh" check "$PLATFORM" | sed 's/^/  /' || bad=1

echo "== 2. Cluster-scoped object names"
rendered=$(helm template idig "$ROOT/charts/idig" -f "$VALUES" --set deployment.wave=all -n "$NS" 2>&1) \
  || { fail "helm template failed: $(head -3 <<<"$rendered")"; rendered=""; }
if [ -n "$rendered" ]; then
  while read -r kind name; do
    res=$(tr 'A-Z' 'a-z' <<<"$kind")
    owner=$("$KUBECTL" get "$res" "$name" -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-namespace}' 2>/dev/null) || continue
    if [ "$owner" = "$NS" ]; then ok "$kind/$name exists, owned by this namespace's release (upgrade)"
    else fail "$kind/$name already exists (owner release namespace: '${owner:-none}') -- set global.clusterResourcePrefix to avoid it"; fi
  done < <(awk '/^---/{k=""} /^kind: (ClusterRole|ClusterRoleBinding|MutatingWebhookConfiguration|ValidatingWebhookConfiguration)$/{k=$2; next} k!=""&&/^  name: /{print k, $2; k=""}' <<<"$rendered" | sort -u)
  [ $bad = 0 ] && ok "no collision with existing cluster-scoped objects"
fi

echo "== 3. Operators of other namespaces on this cluster"
found=0
while IFS=$'\t' read -r ns name image envs; do
  [ "$ns" = "$NS" ] && continue
  found=1
  case "$image" in
    *valkey-operator*)
      if grep -q 'WATCH_NAMESPACE' <<<"$envs"; then ok "$ns/$name: WATCH_NAMESPACE set"
      else fail "$ns/$name (Valkey operator) has no WATCH_NAMESPACE: it watches every namespace and would also reconcile this install's Valkey"; fi ;;
    *datapower-nano-operator*)
      if grep -q 'DPN_LABEL_SELECTOR' <<<"$envs"; then ok "$ns/$name: DPN_LABEL_SELECTOR set"
      else fail "$ns/$name (nano operator) has no DPN_LABEL_SELECTOR: it reconciles every namespace's nano resources"; fi ;;
    *idig-gw-operator*)
      note "$ns/$name: another idig-gw-operator exists; check its IDIG_LABEL_SELECTOR does not overlap this install's" ;;
  esac
done < <("$KUBECTL" get deploy -A -o json 2>/dev/null | jq -r '.items[] | select(.spec.template.spec.containers[0].image | test("valkey-operator|datapower-nano-operator|idig-gw-operator")) | [.metadata.namespace, .metadata.name, .spec.template.spec.containers[0].image, ([.spec.template.spec.containers[0].env[]?.name] | join(","))] | @tsv')
[ $found = 0 ] && ok "no such operator in another namespace"

echo "== 4. API Connect operator (OLM) already on the cluster"
app=$(awk '/^appVersion:/{gsub(/"/,"",$2); print $2}' "$ROOT/charts/idig/Chart.yaml")
csvs=$("$KUBECTL" get csv -A -o json 2>/dev/null | jq -r '.items[] | select(.metadata.name | startswith("ibm-apiconnect")) | "\(.metadata.namespace)\t\(.metadata.name)"')
if [ -z "$csvs" ]; then ok "none"; else
  while IFS=$'\t' read -r ns csv; do note "$ns/$csv present; this chart's appVersion is $app -- the CRDs are shared, so keep both on the same 12.1.1.x"; done <<<"$csvs"
fi

echo
if [ $bad = 1 ]; then echo "✗ preflight found blocking problems."; exit 1; fi
[ $warn = 1 ] && echo "✓ preflight passed with warnings." || echo "✓ preflight passed."
