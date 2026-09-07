# Workaround: IDIG operator ignores `spec.imageRegistry` for some components

**Affects:** IDIG 12.1.1.2 on OpenShift 4.19  
**Discovered:** 2026-09-01  
**Status:** Resolved — workaround applied to cluster `itz-h670hx`

---

## Problem

The IDIG operator deploys several sub-component Deployments whose container
image references are **fully hardcoded** inside the operator binary, bypassing
the `spec.imageRegistry` field of the `DatapowerInteractGatewayCluster` CR
entirely.

The first confirmed instance is the analytics-proxy component:

```
# Image the operator injects into the Deployment — hardcoded, not derived from spec.imageRegistry
docker-na.artifactory.swg-devops.com/apic-dev-docker-local/velox/analytics-v2-proxy:2026-08-25-06-54-13-v12.1.1-248a78c10e1581287ceb23d9e89f81bbc5bd055b.amd64
```

In an air-gapped or private-registry deployment where `spec.imageRegistry` is
set to a local Quay instance, the correct mirrored image exists at:

```
quay-quay-quay.apps.itz-h670hx.infra01-lb.fra02.techzone.ibm.com/ibmorg/analytics-v2-proxy:<tag>
```

But the pod never attempts to pull from there — it goes directly to IBM's
internal Artifactory, which is unreachable from the cluster, and enters
`ImagePullBackOff`.

The same hardcoding pattern has been observed for the NanoGateway operator
components (`cp.icr.io/cp/datapower/datapower-nano-*`).

---

## Root cause

The IDIG operator constructs full image URIs internally for some components
rather than prefixing `spec.imageRegistry` uniformly. This is an operator
implementation issue; patching the Deployment manually is not a durable fix
because the operator overwrites it on every reconciliation loop.

---

## Workaround

Two cluster-level changes are required. Both are one-time operations per
cluster and survive operator reconciliations.

### Step 1 — `ImageTagMirrorSet`: redirect pulls at the CRI-O level

Create an `ImageTagMirrorSet` (OCP 4.13+) that instructs CRI-O on every node
to transparently redirect pulls from the IBM-internal source registries to the
local Quay mirror:

```bash
oc apply -f charts/idig/docs/imagetagmirrorset-idig.yaml
```

The file [`imagetagmirrorset-idig.yaml`](imagetagmirrorset-idig.yaml) maps:

| Source (hardcoded by the operator) | Mirror (local Quay) |
|---|---|
| `docker-na.artifactory.swg-devops.com/apic-dev-docker-local/velox` | `quay-quay-quay.apps.itz-h670hx.infra01-lb.fra02.techzone.ibm.com/ibmorg` |
| `cp.icr.io/cp/datapower` | `quay-quay-quay.apps.itz-h670hx.infra01-lb.fra02.techzone.ibm.com/ibmorg` |

Applying this resource triggers a **rolling reboot** of all MachineConfigPools
(MCO propagates the new CRI-O `registries.conf` to every node). Monitor
progress with:

```bash
watch oc get mcp
watch oc get nodes
```

Expect ~5–10 minutes per node. All MCPs must reach `UPDATED=True` before
proceeding to Step 2.

### Step 2 — Global pull secret: add Quay credentials at the node level

The ITMS mirror redirect works at the CRI-O level, but CRI-O **does not
forward pod-level `imagePullSecrets` to mirrors**. Authentication for the
mirror registry must be present in the node-level credential store
(`/var/lib/kubelet/config.json`), which is populated from the cluster global
pull secret (`openshift-config/pull-secret`).

Merge the Quay credentials into the global pull secret (non-destructive — only
adds the new registry entry, all existing credentials are preserved):

```bash
CURRENT=$(oc get secret/pull-secret -n openshift-config \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d)

QUAY_AUTH=$(oc get secret idig-registry-secret -n idig \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d)

MERGED=$(python3 -c "
import json
cur = json.loads('''$CURRENT''')
new = json.loads('''$QUAY_AUTH''')
cur['auths'].update(new['auths'])
print(json.dumps(cur))
")

oc set data secret/pull-secret -n openshift-config \
  --from-literal=.dockerconfigjson="$MERGED"
```

> **Note:** unlike the ITMS step, updating the global pull secret does **not**
> trigger a node reboot on OCP 4.13+. The
> `node-credential-rotation-controller` distributes the new credentials to all
> nodes in-place within seconds.

### Step 3 — Restart affected pods

Once both steps above are applied, force the affected pods to restart so they
pick up the new CRI-O mirror config and node credentials:

```bash
oc rollout restart deployment/idig-analytics-proxy -n idig
```

For any other pod still in `ImagePullBackOff` after the ITMS rolling reboot
completes, a simple pod delete is sufficient:

```bash
oc delete pod <pod-name> -n idig
```

---

## Verification

After Step 3, the pod event log should show CRI-O attempting the mirror first:

```
Pulling image "docker-na.artifactory.swg-devops.com/.../analytics-v2-proxy:<tag>"
# CRI-O internally redirects to:
# quay-quay-quay.apps.itz-h670hx.infra01-lb.fra02.techzone.ibm.com/ibmorg/analytics-v2-proxy:<tag>
```

The pod should reach `1/1 Running`. Confirm with:

```bash
oc get pods -n idig | grep analytics-proxy
# expected: 1/1  Running
```

---

## Scope and limitations

- The ITMS and global pull secret entries are **cluster-scoped** — they apply
  to all namespaces, not just `idig`. This is acceptable since the source
  registries being mirrored (`docker-na.artifactory.swg-devops.com`,
  `cp.icr.io/cp/datapower`) are only used by IDIG/APIC workloads on this
  cluster.
- The mirrored image tag pulled by the operator
  (`2026-08-25-06-54-13-v12.1.1-...`) may differ from the tag listed in the
  `retagged-idig-image-list.yaml` bundle (`2026-08-26-11-10-06-v12.1-saas-...`).
  Both tags must be present in the local Quay. If the operator-requested tag is
  missing, re-run `scripts/mirror-images.sh` against the specific bundle
  version the operator was built with.
- This workaround will be **unnecessary** if a future IDIG operator release
  fixes the hardcoded registry issue and consistently respects
  `spec.imageRegistry` for all components. Re-evaluate when upgrading to a
  newer operator version.
