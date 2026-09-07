# `kubeVersion` constraint: why it's `>=1.27.0-0`, not `>=1.33.0-0`

## The contradiction in IBM's own version data

`idig-operator-release-files_12.1.1.2/operand-version.yaml` states, for the
current GA version (`12.1.1.2-0`):

```yaml
minK8SVersion: "1.33"
recomendedK8SVersion: ">=1.33, <1.36"
minOCPVersion: "4.14"
recomendedOCPVersion: ">=4.14, <4.20"
```

These two constraints are mutually incompatible on OpenShift. OCP's
Kubernetes version is fixed per OCP release (it's not chosen independently),
and every OCP version in IBM's own "recommended" window maps to a
Kubernetes version below 1.33:

| OCP version | Kubernetes version |
|---|---|
| 4.14 | 1.27 |
| 4.15 | 1.28 |
| 4.16 | 1.29 |
| 4.17 | 1.30 |
| 4.18 | 1.31 |
| 4.19 | 1.32 |
| 4.20 (excluded by `recomendedOCPVersion`) | 1.33 |

So `recomendedOCPVersion: ">=4.14, <4.20"` and `minK8SVersion: "1.33"` can
never both be satisfied at once — no OCP version in the range IBM
recommends actually ships Kubernetes 1.33. This was hit directly: `helm
upgrade --install` on a real OCP 4.19.38 cluster (Kubernetes v1.32.13, well
inside IBM's stated OCP support window) failed outright with `Error: chart
requires kubeVersion: >=1.33.0-0 which is incompatible with Kubernetes
v1.32.13` when `Chart.yaml` mirrored `minK8SVersion` literally.

## The fix applied

`Chart.yaml`'s `kubeVersion` was relaxed to `>=1.27.0-0` -- the Kubernetes
version backing OCP 4.14, the actual minimum IBM says it supports on that
platform. This unblocks OCP deployments within IBM's documented support
window. It's a deliberate, informed relaxation of Helm's own gate, not an
attempt to override IBM's real compatibility requirements.

**On OpenShift**, `minOCPVersion`/`recomendedOCPVersion` are the
constraints that actually apply and matter -- these aren't enforced by
Helm's `kubeVersion` gate (Helm has no native way to make `kubeVersion`
platform-conditional), so they're just documented in the chart README's
OpenShift Prerequisites section instead ("4.14 or later, but earlier than
4.20 -- verify manually").

**On vanilla Kubernetes**, where `minOCPVersion` doesn't apply and
`minK8SVersion: 1.33` is the real, uncontradicted IBM requirement, Helm's
`kubeVersion` gate no longer catches a sub-1.33 cluster automatically
(the chart-wide constraint had to move down to 1.27 to not break OCP).
There is currently no separate Kubernetes-specific version check in this
chart -- if this bites in practice, the fix would be a `fail` in
`_helpers.tpl` gated on `envoyGateway.enabled` (a reasonable proxy for
"this is the Kubernetes path, not the OpenShift path" given how those
values are set today) rather than tightening `Chart.yaml` itself again.

## What this doesn't resolve

Whether IDIG 12.1.1.2 genuinely requires Kubernetes 1.33+ specific APIs/
behavior even when running *underneath* OCP 4.14-4.19 (i.e., whether IBM's
`minK8SVersion` is a real technical requirement being violated by every
OCP 4.14-4.19 install, or just an unreconciled leftover from a version
matrix built primarily around vanilla Kubernetes) is unknown and wasn't
investigated further. If IDIG behaves unexpectedly on an in-window OCP
cluster, this contradiction is the first thing to revisit.
