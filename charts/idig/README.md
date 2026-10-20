# IBM DataPower Interact Gateway (IDIG) Helm Chart

Helm chart for deploying IBM DataPower Interact Gateway (IDIG) 12.1.1.

## Prerequisites

**Cluster access:**

- A container registry populated with all IDIG/APIC/NanoGateway/Valkey images. See [the repo root README](../../README.md) for how to obtain the images/signatures from IBM Fix Central and mirror them with `scripts/mirror-images.sh`.
- Cluster admin access (for CRDs and cluster-scoped RBAC).
- A default StorageClass, or set `global.storageClass` explicitly.

**Minimum cluster sizing** (per `idigCluster.profile`):

- `dev`: at least 2 CPU / 16 GB available in the cluster.
- `prod`: 7 to 14.55 CPU cores and 7.5 to 13.5 GB memory, depending on replica count (2-3 replicas).

**If `idigCluster.enableAnalytics=true`** (the `values-prod.yaml` default): every worker node needs `vm.max_map_count >= 262144` for the Analytics/OpenSearch component. Raise it via a DaemonSet/node-level `sysctl` on Kubernetes, or a `MachineConfig` on OpenShift — this chart does not set it for you.

**IDIG operator hardcodes some image URIs** — the IDIG operator v12.1.1.x constructs full image references internally for some components (e.g. `analytics-proxy`, NanoGateway datapower images), bypassing `spec.imageRegistry`. In an air-gapped deployment, CRI-O-level mirrors and a cluster-level pull secret are required to redirect those pulls to your local registry. See [`docs/hardcoded-image-registry-workaround.md`](docs/hardcoded-image-registry-workaround.md) for the full procedure.

**Namespace:**

```bash
export NAMESPACE=idig
kubectl create namespace $NAMESPACE
```

**Registry credentials** — required whenever `global.imageRegistry` is set (the chart fails the render otherwise), including for the OpenShift internal registry in the same namespace:

```bash
kubectl create secret docker-registry idig-registry-secret \
  --docker-server=<your-registry> \
  --docker-username=<user> \
  --docker-password=<password> \
  -n $NAMESPACE
# then set global.imagePullSecret=idig-registry-secret in your values
```

**IBM entitlement key** — only needed if pulling some images directly from `cp.icr.io`.

```bash
kubectl create secret docker-registry ibm-entitlement-key \
  --docker-server=cp.icr.io/cp/datapower \
  --docker-username=cp \
  --docker-password=<your-entitlement-key> \
  -n $NAMESPACE
```

**WatsonX credentials** — optional. Skip this to leave the GenAI service undeployed.

```bash
kubectl create secret generic watsonx-credentials \
  --from-literal=WATSONX_API_KEY=<key> \
  --from-literal=WATSONX_PROJECT_ID=<project-id> \
  -n $NAMESPACE
```

### Kubernetes-only

**cert-manager:**

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.20.3/cert-manager.yaml
kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=cert-manager -n cert-manager --timeout=180s
```

**Envoy Gateway v1.7.0:**

```bash
kubectl apply --force-conflicts --server-side \
  -f https://github.com/envoyproxy/gateway/releases/download/v1.7.0/install.yaml
kubectl wait --timeout=300s --for=condition=available \
  deployment/envoy-gateway -n envoy-gateway-system
```

Envoy Gateway ships with Backend CR support disabled. Enable it by patching its ConfigMap non-interactively (requires `yq` and `jq`):

```bash
NEW_DATA=$(kubectl get configmap envoy-gateway-config -n envoy-gateway-system \
  -o jsonpath='{.data.envoy-gateway\.yaml}' \
  | yq eval '.extensionApis.enableBackend = true' -)
kubectl patch configmap envoy-gateway-config -n envoy-gateway-system \
  --type=merge -p "$(jq -n --arg v "$NEW_DATA" '{data: {"envoy-gateway.yaml": $v}}')"
kubectl rollout restart deployment envoy-gateway -n envoy-gateway-system
kubectl rollout status deployment envoy-gateway -n envoy-gateway-system --timeout=120s
```

The Gateway API CRDs are applied by `make crds PLATFORM=k8s` (see "CRDs" below). The IDIG-specific `EnvoyProxy`/`GatewayClass` on top of the controller above do not need a separate step — this chart creates them automatically (`templates/wave0-envoy-gateway.yaml` gated by `envoyGateway.enabled=true`, the default).

### OpenShift-only

**OpenShift support requires IDIG 12.1.1.2 or later** — versions 12.1.1.0 and 12.1.1.1 support Kubernetes only. This chart's `Chart.yaml` tracks `appVersion: "12.1.1.3"`, so this is already satisfied as long as you don't override `global.imageRegistry`/tags to point at an older release.

**OpenShift version:** 4.14 or later, but earlier than 4.20. `Chart.yaml`'s `kubeVersion` constraint does not capture this OCP-specific ceiling — verify manually.

**Envoy Gateway/Gateway API does not apply to OpenShift at all.** IDIG exposes its endpoints through plain OpenShift `Route` objects in front of an internal `idig-envoy-proxy` Service; there is no `Gateway`/`HTTPRoute`/`EnvoyProxy`/`GatewayClass` involved anywhere in an OCP deployment. Set `envoyGateway.enabled=false` (already the case in `examples/values-ocp.yaml`) so this chart doesn't create them.

**cert-manager must be installed via OLM on OCP** — the raw Kubernetes manifest above is not compatible with OpenShift:

```bash
# Install the "cert-manager Operator for Red Hat OpenShift" from OperatorHub
# (Operators -> OperatorHub -> search "cert-manager"), or via CLI:
oc apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-cert-manager-operator
  namespace: cert-manager-operator
spec:
  channel: stable-v1
  name: openshift-cert-manager-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
# Wait for the CSV to reach Succeeded before proceeding:
oc get csv -n cert-manager-operator
```

If wave 0 (or any cert-manager resource) fails to reconcile with an `OperatorDependencyNotInstalled`-style error, this OLM operator is missing or not yet `Succeeded` — check `oc get csv -n cert-manager-operator` and the `certmanagers.operator.openshift.io` CRD before troubleshooting further.

**OpenShift wildcard routes** — the NanoGateway component uses a wildcard `Route` (`wildcardPolicy: Subdomain`) to expose `*.nanogw.<domain>`. OpenShift's default Ingress Controller rejects wildcard routes unless explicitly permitted. Enable it once per cluster:

```bash
oc patch ingresscontroller default -n openshift-ingress-operator \
  --type=merge \
  -p '{"spec":{"routeAdmission":{"wildcardPolicy":"WildcardsAllowed"}}}'
# The Ingress Operator rolls out new router pods to apply the change (~1-2 min).
# Verify the NanoGateway route is admitted afterwards:
oc get route idig-nanogw-nanogw -n $NAMESPACE
# Expected: Subdomain (not RouteNotAdmitted)
```

> **Note:** this setting is cluster-wide. On a shared cluster, check with the cluster admin before enabling it — it allows any namespace to create wildcard routes.

## Key values

| Value | Purpose |
|---|---|
| `global.namespace` | Target namespace for every resource. |
| `global.operatorScope` | Only `singleNamespace` is supported today. Any other value fails the render on purpose. |
| `global.imageRegistry` | Your mirrored registry (or `cp.icr.io/cp/datapower`). |
| `global.imagePullSecret` | Registry pull secret name, or `""` (default) to omit `imagePullSecrets` entirely. |
| `global.ibmEntitlementKeySecret` | Name of the `ibm-entitlement-key` secret, or `""` to omit it. |
| `global.domain` | Base domain for all ingress endpoints. |
| `global.license.accept` | Must be `true` to proceed. |
| `idigCluster.profile` | `dev` (minimal resources) or `prod` (high availability). See "Minimum cluster sizing" above for the resources each profile needs available. |
| `idigCluster.enableAnalytics` / `idigCluster.enableDevPortal` | Toggle optional subsystems. `enableAnalytics=true` also requires the `vm.max_map_count` prerequisite above and `idigCluster.analyticsSettings.clientSubjectDN` to be set (see below). |
| `idigCluster.watsonxSecret` | Name of the WatsonX credentials secret, or empty to skip the GenAI service. |
| `idigCluster.tenantName` / `idigCluster.groupName` | Tenant and group identifiers IBM's planning docs ask you to choose up front — see `deployment-overview-endpoints-certificates` in IBM's docs for how these map to endpoint hostnames. |
| `idigCluster.analyticsSettings.clientSubjectDN` | mTLS client cert subject DN for the Analytics ingestion endpoint. Defaults to `CN=analytics-ingestion-client,O=cert-manager` (CN must come before O per RFC 2253 — don't reorder). Required whenever `enableAnalytics=true`; the IDIG operator's admission webhook rejects *any* CR patch, including a version bump during an upgrade, if this is unset while analytics is enabled. |
| `idigCluster.customIngressCertificate` | Bring-your-own ingress certificate secret name, or empty to use the cert-manager-issued one from wave 0. |
| `idigCluster.analyticsStorage.*` / `idigCluster.devPortalStorage.*` | Storage class/size overrides for the Analytics and Developer Portal persistent volumes. Only relevant when the corresponding subsystem is enabled. |
| `issuer.createSelfSigned` | `true` (default) creates a self-signed issuer chain in wave 0. Set `false` to use your own Issuer/ClusterIssuer. |
| `issuer.name` / `issuer.kind` | The cert-manager issuer every IDIG Certificate is issued from. To use a company PKI `ClusterIssuer`: set `createSelfSigned=false` and point these two here — no other value needs to change. |
| `envoyGateway.*` | Names Envoy Gateway resources this chart creates must match (`proxyConfigName`, `gatewayClassName`) and the namespace Envoy Gateway was installed into. |

See `values.yaml` for the full list, organized by wave, and `examples/values-dev.yaml` / `examples/values-prod.yaml` for starting points.

## Deployment

The chart uses a `deployment.wave` parameter to control which components are deployed:

| Wave | Deploys |
|---|---|
| 0 | IDIG's cert-manager Issuer/CA/Certificates |
| 1 | All operators — APIC, Valkey, IDIG NanoGateway (`idig-gw-operator`, which replaces the separate NanoGateway operator since 12.1.1.3), IDIG operator |
| 2 | The Valkey instance |
| 3 | The IDIG cluster (`DatapowerInteractGatewayCluster` custom resource) |

Waves 0 and 1 have no dependency on each other beyond cert-manager/Envoy Gateway being ready. Wave 2 needs the Valkey operator (wave 1) running. Wave 3 needs the IDIG operator (wave 1) and Valkey (wave 2) both ready.

For ArgoCD/GitOps, set `deployment.wave=all` and let ArgoCD sequence the waves itself via the `argocd.argoproj.io/sync-wave` annotations already present on every resource.

```bash
export NAMESPACE=idig
export VALUES_FILE=examples/values-dev.yaml   # or examples/values-prod.yaml
```

### Wave 0

```bash
helm upgrade --install idig-prereqs . -f $VALUES_FILE --set deployment.wave=0 -n $NAMESPACE
```

The CRDs are **not** installed by this chart: run `make crds PLATFORM=<k8s|ocp>` first (see "CRDs").

Wait for the issuer and all certificates to be ready (cert-manager issues all 8 leaf certs from the trust chain; this normally takes a few seconds):

```bash
# If issuer.createSelfSigned=true (default): wait for the self-signed issuer chain first
kubectl wait --for=condition=ready issuer/selfsigning-issuer issuer/ingress-issuer \
  -n $NAMESPACE --timeout=60s

# Wait for all 8 application certificates to reach Ready state
kubectl wait certificate --all -n $NAMESPACE --for=condition=Ready --timeout=120s
kubectl get certificates -n $NAMESPACE
```

> **Kubernetes only:** this wave also creates the `EnvoyProxy`/`GatewayClass`
> resources IDIG needs on top of the Envoy Gateway controller installed in
> "Prerequisites" above (`templates/wave0-envoy-gateway.yaml`, gated by
> `envoyGateway.enabled=true`, the default). On OpenShift, where this has no
> equivalent, `examples/values-ocp.yaml` sets `envoyGateway.enabled=false`
> and this template renders nothing.

### Wave 1

```bash
helm upgrade --install idig-operators . -f $VALUES_FILE --set deployment.wave=1 -n $NAMESPACE
```

Wait for the operators to be ready:

```bash
kubectl -n $NAMESPACE rollout status deployment/ibm-apiconnect
kubectl -n $NAMESPACE rollout status deployment/valkey-operator
kubectl -n $NAMESPACE rollout status deployment/idig-gw-operator
kubectl -n $NAMESPACE rollout status deployment/idig-operator
```

### Wave 2

Requires `valkey-tls` (auto-created by wave 0). This wave auto-creates `valkey-secret` itself.

```bash
helm upgrade --install idig-valkey . -f $VALUES_FILE --set deployment.wave=2 -n $NAMESPACE
```

Wait for Valkey to be ready:

```bash
kubectl -n $NAMESPACE wait --for=condition=ready pod -l app.kubernetes.io/name=valkey --timeout=300s
```

### Wave 3

```bash
helm upgrade --install idig-cluster . -f $VALUES_FILE --set deployment.wave=3 -n $NAMESPACE
```

Track the rollout — this can take up to 20 minutes:

```bash
kubectl get datapowerinteractgatewaycluster idig -n $NAMESPACE -o jsonpath='{.status.phase}'
```

### ArgoCD / GitOps mode

```bash
helm upgrade --install idig . -f $VALUES_FILE --set deployment.wave=all -n $NAMESPACE
```

Or, for a native ArgoCD `Application`, set `deployment.wave: "all"` in the values used by the `Application`'s Helm source, and make sure ArgoCD's sync policy respects sync-wave ordering (the default behavior).

## Accessing the IDIG user interfaces

**On Kubernetes**, list the Gateway API ingress endpoints:

```bash
kubectl get gateway,httproute -n $NAMESPACE
```

- `<cr-name>-web` — IDIG Console UI
- `<cr-name>-devportal-devportal-web` — Developer Portal UI, only present if `idigCluster.enableDevPortal=true`

**On OpenShift, there is no Gateway/HTTPRoute at all** — IDIG's operator
creates plain OCP `Route` objects instead (passthrough/reencrypt, in front
of an internal `idig-envoy-proxy` Service). List those instead:

```bash
oc get routes -n $NAMESPACE
```

Console admin credentials:

- **Username:** `administrator`

  This is a fixed UMC login id — **not** the email address stored in the
  secret. The secret's `email` field is only a profile attribute; logging in
  with the email fails with *"Invalid username or password"*.

- **Password:**

  ```bash
  kubectl get secret <cr-name>-idig-admin-pass -n $NAMESPACE \
    -o jsonpath='{.data.password}' | base64 -d && echo
  ```

On first successful login you are prompted to change the password (the
secret's `forcePasswordChange` field is `true`).

## Upgrading

IBM only supports **n→n+1 upgrades** — e.g. 12.1.1.1→12.1.1.2 is supported,
a direct 12.1.1.0→12.1.1.2 jump is not. Check the IDIG cluster's current
`spec.version` before starting:

```bash
kubectl get datapowerinteractgatewaycluster idig -n $NAMESPACE -o jsonpath='{.spec.version}'
```

**Back up before upgrading** — IBM's documented upgrade procedure requires
a backup of the IDIG CR itself and of every cert-manager resource
(Issuers/Certificates/Secrets) in `$NAMESPACE`:

```bash
kubectl get datapowerinteractgatewaycluster idig -n $NAMESPACE -o yaml > idig-cr-backup.yaml
kubectl get issuer,certificate,secret -n $NAMESPACE -o yaml > cert-manager-backup.yaml
```

**If `idigCluster.enableAnalytics=true`, set `idigCluster.analyticsSettings.clientSubjectDN` before touching anything else.** The IDIG operator's admission webhook validates this field on *every* CR patch when analytics is enabled — including the version bump a `helm upgrade` performs. An unset value here will make the upgrade fail at the webhook, not at Helm.

**Upgrade order** (this chart's wave grouping doesn't currently express this — until it does, upgrade the operator images/values one wave-1 component at a time rather than all at once): CRDs (`make crds`) → Valkey operator → APIC → IDIG NanoGateway (`idig-gw-operator`) → IDIG operator, and only then bump the IDIG cluster CR's `spec.version` (wave 3).

**12.1.1.2 → 12.1.1.3 specifics:**

- The separate `datapower-nano-operator` Deployment is gone; `idig-gw-operator` now does its job. `helm upgrade` removes the old Deployment and its ClusterRole/ClusterRoleBinding.
- Cluster-scoped objects are renamed with a per-namespace prefix (`global.clusterResourcePrefix`, default: the namespace), so the old, unprefixed ones are removed by the upgrade and recreated under the new names.
- Valkey moves to `valkey-bundle:9.1` with a **persistent volume** (`valkey.storage`). IBM's procedure ("Migrate Valkey to Persistent Storage", in the release's README) must be followed for an existing Valkey. `persistentVolumeClaimRetentionPolicy.whenDeleted` is now `Retain`: deleting the Valkey no longer deletes its volume.
- `idigCluster.nanoGateway.gatewayDomain` now defaults to `idig.<global.domain>` (was `nanogw.<global.domain>`). Set it explicitly to keep the previous value.
- `idigOperator.image` overrides in older values files (the 12.1.1.2 ifix) must be removed.

**Re-apply CRDs before bumping each operator** — IBM's upgrade procedure treats a CRD refresh as a required step per release:

```bash
make crds-check PLATFORM=ocp   # read-only: what differs from the cluster
make crds PLATFORM=ocp
```

**cert-manager itself may also need upgrading** as part of this flow — check the target IDIG release's compatible cert-manager version (currently v1.21.1, see "Prerequisites") before proceeding, and upgrade it via the same method you originally installed it with (raw manifest on Kubernetes, OLM subscription channel on OpenShift).

Then, once every operator and cert-manager are on the right versions, bump the values and re-run the wave-1 and wave-3 installs:

```bash
helm upgrade --install idig-operators . -f $VALUES_FILE --set deployment.wave=1 -n $NAMESPACE
helm upgrade --install idig-cluster . -f $VALUES_FILE --set deployment.wave=3 -n $NAMESPACE
kubectl get datapowerinteractgatewaycluster idig -n $NAMESPACE -o jsonpath='{.status.phase}'
```

**No rollback procedure is documented by IBM or implemented by this chart.** If an upgrade fails partway, restoring from the backups above and re-installing the previous chart values is the only currently-known path back.

## Uninstallation

Remove in reverse order:

```bash
helm uninstall idig-cluster -n $NAMESPACE
helm uninstall idig-valkey -n $NAMESPACE
helm uninstall idig-operators -n $NAMESPACE
helm uninstall idig-prereqs -n $NAMESPACE   # only if you installed wave 0 yourself
```

Helm does not remove CRDs it created. Clean up secrets and CRDs separately if a full teardown is needed.

## CRDs

CRDs are cluster-scoped and can be shared with other installs on the same cluster (typically API Connect), so this chart does not install them: they live in `crds/` at the repo root and are applied by a dedicated target.

```bash
make crds-check PLATFORM=ocp   # read-only: compare crds/ with the cluster
make crds PLATFORM=ocp         # check, then server-side apply and wait Established
```

`crds-check` classifies each CRD (descriptions ignored): `new`, `identical`, `additive` (the bundle only adds fields or enum values), `changed` (same fields, different values; review) and `INCOMPAT` (a field or version present on the cluster is missing from the bundle; `make crds` stops unless `FORCE=1`). `make prereqs` and `make deploy` run `make crds` first.

`make crds` skips what it must not touch: the Gateway API CRDs on OpenShift (managed by the Ingress Operator) and the APIC/DataPower/EDB CRDs when API Connect is already installed (`APPLY_APIC=1` forces them). See `crds/README.md` for the origin and version of each file.

## Coexisting with API Connect in another namespace

Each install deploys its own operators and Valkey in its own namespace. Because some objects are cluster-scoped, three things keep two installs from interfering:

1. **Names.** ClusterRoles, ClusterRoleBindings and webhook configurations are prefixed with `global.clusterResourcePrefix` (default: the namespace). Their webhooks only apply to objects of this install's namespace (`namespaceSelector`).
2. **Valkey operator.** `WATCH_NAMESPACE` restricts it to its own namespace (`valkeyOperator.watchNamespace`). The API Connect install's own Valkey operator must be restricted the same way, otherwise it also reconciles this install's Valkey.
3. **NanoGateway operator.** The API Connect operator (`datapower-nano-operator`) only supports a label filter (`DPN_LABEL_SELECTOR`, e.g. `managed-by!=idig`); it cannot be limited to a namespace. This chart's `idig-gw-operator` is driven by `idigNanoGatewayOperator.labelSelector` (`IDIG_LABEL_SELECTOR`), whose vendor default `managed-by!=XXXXXXXXXXXXXXXXXXX` matches every object. **Open point:** which label the 12.1.1.3 IDIG components put on the nano resources they create has not been verified; the two selectors must partition the objects of the two installs.

`make preflight PLATFORM=ocp NAMESPACE=idig VALUES_FILE=...` checks all of this read-only against the cluster before installing: name collisions, whether the operators of other namespaces are restricted, CRD compatibility, and the API Connect version present.

## Notes on this chart's construction

**Envoy Gateway configuration is Kubernetes-only, gated by `envoyGateway.enabled`.** `templates/wave0-envoy-gateway.yaml` creates the `EnvoyProxy`/`GatewayClass` resources IDIG needs on top of an already-installed Envoy Gateway controller. On OpenShift, where this has no equivalent (IDIG uses plain `Route` objects instead of Gateway API), `examples/values-ocp.yaml` sets `envoyGateway.enabled=false` so the template renders nothing. (Enabling Backend CR support on the `envoy-gateway-config` ConfigMap, covered in "Prerequisites" above, stays a manual step for a different reason: that object always pre-exists from Envoy Gateway's own install, and Helm cannot adopt a pre-existing object without ownership annotations already set on it.)

**Third-party operator manifests** (APIC, NanoGateway, Valkey operator) are each templated as a single file, with only the vendor's placeholders substituted — their internal RBAC/webhooks/Services are not reorganized. IDIG's own operator resources are split into namespace-scoped vs. cluster-scoped files to prepare for a future `clusterWide` operator scope.

**Wave 0's cert-manager resources** are split into `wave0-issuers.yaml` (the trust chain: `selfsigning-issuer`, `ingress-ca`, `issuer.name`) and `wave0-certificates.yaml` (the application leaf Certificates, including `valkey-tls`). This split means switching to a cluster-level issuer later only touches `wave0-issuers.yaml` / `issuer.*` values, never the certificates file.
