# CRDs

Cluster-scoped, possibly shared with other installs on the same cluster, so they are
**not** part of the Helm chart. Applied by `make crds`, compared with the cluster by
`make crds-check` (see `scripts/crds.sh` and `charts/idig/README.md` "CRDs").

| File | Content | Source (vendor bundle 12.1.1.3) |
|---|---|---|
| `idig-operator.yaml` | `DatapowerInteractGatewayCluster` (shortName `idigc`) | `idig-crds.yaml` |
| `nanogateway.yaml` | 17 CRDs `nano.datapower.ibm.com` and `idig.datapower.ibm.com` (operator 1.1.0) | `dependencies/ibm-nanogw-crds.yaml` |
| `valkey.yaml` | 4 CRDs `valkey.datapower.ibm.com` | `dependencies/valkey-crds.yaml` |
| `apic.yaml` | API Connect, DataPower and EDB Postgres CRDs (operator 1.18.5) | `dependencies/ibm-apiconnect-crds.yaml` |
| `gateway-api.yaml` | Gateway API (experimental install v1.4.1), Kubernetes only | `helper_files/gateway-api-experimental-install-v1.4.1.yaml` |

To update for a new release: copy the files from the new bundle over these ones, run
`make crds-check`, review the `changed`/`INCOMPAT` lines, then `make crds`.
