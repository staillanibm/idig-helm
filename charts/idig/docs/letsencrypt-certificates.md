# Configuring Let's Encrypt certificates for IDIG's public endpoints

## Prerequisite: a DNS-01 `ClusterIssuer`

Both public domains below (`global.domain` and `nanoGateway.gatewayDomain`)
need a wildcard certificate, and the NanoGateway route is TLS passthrough
— so ACME HTTP-01 cannot be used for either. A DNS-01 `ClusterIssuer` is
required, installed and managed outside this chart.

Setting one up means:
- installing a DNS-01 solver webhook that matches your DNS provider (a
  separate Helm release from this chart — e.g. `cert-manager-webhook-ovh`
  for OVH-hosted DNS; every major DNS provider has an equivalent)
- creating a secret holding that provider's API credentials, in the same
  namespace as the webhook deployment
- creating the `ClusterIssuer` itself, referencing that secret and your
  ACME account email

Being cluster-scoped, the resulting `ClusterIssuer` is referenced by name
from any namespace, including `idig` — it only needs to be created once
per cluster, not per install.

IDIG exposes three public HTTPS surfaces, each terminated differently and
each configured differently:

| Surface | Routes | TLS termination | Config mechanism |
|---|---|---|---|
| IDIG web UI / API | `idig-idig-web`, `idig-idig-broker` | `reencrypt` (OCP router) | `idigCluster.customIngressCertificate` |
| Developer portal | `idig-devportal-devportal-web` | `reencrypt` (OCP router) | `idigCluster.customIngressCertificate` |
| NanoGateway (MCP servers / LLM proxies) | `idig-nanogw-nanogw` | `passthrough` (gateway pod terminates) | manual `TlsServerProfile` patch — see below |

## 1. IDIG web UI, API, and developer portal

These three routes are `reencrypt`-terminated by the OCP router, so a
single custom certificate secret covers all of them via one values field:

```yaml
idigCluster:
  customIngressCertificate: "apps-example-com-tls"
```

This is templated straight onto `DatapowerInteractGatewayCluster.spec.customIngressCertificate`
and works as documented — no further steps needed once the secret exists
in the namespace.

To produce that secret:
1. Point `global.domain` at a domain you control (CNAME `*.<global.domain>`
   to the cluster's router).
2. Issue a wildcard certificate for `<global.domain>` / `*.<global.domain>`
   via your own `Issuer`/`ClusterIssuer` (DNS-01 works fine here since
   these routes don't require passthrough).
3. Set `idigCluster.customIngressCertificate` to that secret's name.

Verify:
```bash
echo | openssl s_client -connect idig.<global.domain>:443 -servername idig.<global.domain> 2>&1 \
  | openssl x509 -noout -issuer -subject
```

## 2. NanoGateway public endpoint

The NanoGateway route is TLS **passthrough** — the OCP router does not
terminate it. The NanoGateway runtime pod terminates TLS itself, so
`customIngressCertificate` has no effect here.

### Point the route at your own domain

```yaml
idigCluster:
  nanoGateway:
    gatewayDomain: "nanogw.example.com"
```

Must differ from `global.domain` (the admission webhook rejects the two
being equal). Set up a CNAME for `nanogw.example.com` and
`*.nanogw.example.com` to the cluster's router.

### Issue a wildcard certificate

ACME HTTP-01 will not work through a passthrough route — use a DNS-01
issuer for your DNS provider, requesting `nanogw.example.com` +
`*.nanogw.example.com`, landing in a `kubernetes.io/tls` secret, e.g.
`nanogw-example-com-tls`.

### Patch the TLS listener

**`idigCluster.customCertificates` does not reach this.** That field only
affects `DatapowerInteractGatewayCluster`'s internal PKI (client certs,
analytics-collector certs) — it has no path to the NanoGateway's public
listener. Instead, patch the `TlsServerProfile` CR directly.

One shared `Runtime` per namespace terminates the wildcard route for
every published MCP server/LLM proxy — it's owned by the Gateway API
`Gateway` resource, not by any individual published asset. Find it and
its `TlsServerProfile`:

```bash
NAMESPACE=idig
SECRET_NAME=nanogw-example-com-tls

RUNTIME=$(oc get rt -n "$NAMESPACE" -o json | jq -r '.items[] | select(.metadata.ownerReferences[]?.kind=="Gateway") | .metadata.name')
echo "$RUNTIME"   # e.g. gw-idig-nanogw

PROFILE=$(oc get rt "$RUNTIME" -n "$NAMESPACE" -o jsonpath='{.spec.listeners[0].defaultTlsServerProfile}')
echo "$PROFILE"   # e.g. idig-nanogw-tls-server-profile

oc patch tlsserverprofile "$PROFILE" -n "$NAMESPACE" \
  --type=merge -p "{\"spec\":{\"secret\":\"$SECRET_NAME\"}}"
```

Every individual published-asset `Runtime` (one per MCP server/LLM proxy)
references this same shared profile, so this one patch covers all of
them — there's no need to patch per-asset Runtimes.

Takes effect immediately — no pod restart required. This patch is not
currently expressed in this chart's templates or values files; it must be
reapplied after any fresh install/reinstall.

Verify:
```bash
echo | openssl s_client -connect <mcp-endpoint>:443 -servername <mcp-endpoint> 2>&1 \
  | openssl x509 -noout -issuer -subject -dates
```

