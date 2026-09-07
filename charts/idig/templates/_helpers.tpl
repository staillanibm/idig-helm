{{/*
Target namespace for all IDIG resources.
*/}}
{{- define "idig.namespace" -}}
{{- .Values.global.namespace -}}
{{- end -}}

{{/*
Common labels applied to every resource this chart manages.
*/}}
{{- define "idig.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: idig
{{- end -}}

{{/*
Validate global.operatorScope. Only "singleNamespace" is implemented today;
fail the render on any other value instead of silently behaving like
singleNamespace or half-implementing clusterWide.
*/}}
{{- define "idig.validateOperatorScope" -}}
{{- $scope := .Values.global.operatorScope -}}
{{- if ne $scope "singleNamespace" -}}
{{- fail (printf "global.operatorScope=%q is not supported yet -- only \"singleNamespace\" is implemented. \"clusterWide\" is a planned future extension, not built." $scope) -}}
{{- end -}}
{{- end -}}

{{/*
Validate global.imagePullSecret is set whenever global.imageRegistry is.
A configured registry always needs an explicit pull secret (including the
OpenShift internal registry in the same namespace).
*/}}
{{- define "idig.validateImagePullSecret" -}}
{{- if and .Values.global.imageRegistry (not .Values.global.imagePullSecret) -}}
{{- fail "global.imageRegistry is set but global.imagePullSecret is empty. A pull secret is required whenever a registry is configured." -}}
{{- end -}}
{{- end -}}

{{/*
Current wave, coerced to string for comparisons.
*/}}
{{- define "idig.wave" -}}
{{- .Values.deployment.wave | toString -}}
{{- end -}}

{{/*
imagePullSecrets: block for a PodSpec (list of {name: ...} objects).
Renders nothing (not even an empty "imagePullSecrets:" key) when
global.imagePullSecret is empty -- e.g. same-namespace pulls from the
OpenShift internal registry, where the default ServiceAccount's
auto-generated pull secret already covers it and no explicit secret is
needed. Indent with `nindent` or `indent` at the call site.
*/}}
{{- define "idig.imagePullSecrets" -}}
{{- if .Values.global.imagePullSecret }}
imagePullSecrets:
- name: {{ .Values.global.imagePullSecret }}
{{- end -}}
{{- end -}}

{{/*
imagePullSecrets: block for a PodSpec that pulls from BOTH
global.imageRegistry (global.imagePullSecret) AND cp.icr.io
(global.ibmEntitlementKeySecret) -- e.g. the NanoGateway operator, whose
image is hardcoded to cp.icr.io/cp/datapower/... by the vendor manifest
regardless of global.imageRegistry. Kubernetes tries every listed secret
against a given registry, so listing both here is safe even though only
one will actually match cp.icr.io. Omits the key entirely if both are
empty.
*/}}
{{- define "idig.imagePullSecretsWithEntitlement" -}}
{{- $secrets := list -}}
{{- if .Values.global.imagePullSecret -}}
{{- $secrets = append $secrets .Values.global.imagePullSecret -}}
{{- end -}}
{{- if .Values.global.ibmEntitlementKeySecret -}}
{{- $secrets = append $secrets .Values.global.ibmEntitlementKeySecret -}}
{{- end -}}
{{- if $secrets }}
imagePullSecrets:
{{- range $secrets }}
- name: {{ . }}
{{- end }}
{{- end -}}
{{- end -}}

{{/*
imagePullSecrets: block for the DatapowerInteractGatewayCluster CR's
spec.imagePullSecrets (list of plain strings, not {name: ...} objects).
Same empty-string-means-omit behavior as idig.imagePullSecrets.
ibmEntitlementKeySecret is included unconditionally when set, independent
of global.imagePullSecret, since it authenticates a different registry
(cp.icr.io) for a different purpose.
*/}}
{{- define "idig.crImagePullSecrets" -}}
{{- $secrets := list -}}
{{- if .Values.global.imagePullSecret -}}
{{- $secrets = append $secrets .Values.global.imagePullSecret -}}
{{- end -}}
{{- if .Values.global.ibmEntitlementKeySecret -}}
{{- $secrets = append $secrets .Values.global.ibmEntitlementKeySecret -}}
{{- end -}}
{{- if $secrets }}
imagePullSecrets:
{{- range $secrets }}
  - {{ . }}
{{- end }}
{{- end -}}
{{- end -}}
