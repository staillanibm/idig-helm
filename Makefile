# Orchestrates prerequisites + secrets + the 4-wave chart install for IDIG.
# Mirrors charts/idig/README.md exactly -- read that first if you want to
# understand *why* each step exists; this file just automates *running*
# them. Only secret values come from .env (see .env.example); everything
# else is a Makefile variable below.
#
# Usage:
#   cp .env.example .env && $EDITOR .env
#   make deploy PLATFORM=k8s NAMESPACE=idig VALUES_FILE=charts/idig/examples/values-dev.yaml
#   make deploy PLATFORM=ocp NAMESPACE=idig VALUES_FILE=charts/idig/examples/values-ocp.yaml
#
# PLATFORM must be set explicitly (k8s or ocp) -- this Makefile does not
# guess your target platform.

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

NAMESPACE ?= idig
VALUES_FILE ?= charts/idig/examples/values-dev.yaml
PLATFORM ?= ocp
DOMAIN ?=
CR_NAME ?= idig
CHART_DIR := charts/idig

ifneq (,$(wildcard .env))
include .env
export
endif

.DEFAULT_GOAL := help

.PHONY: help
help:
	@echo "Targets:"
	@echo "  make fill-values PLATFORM=k8s|ocp [DOMAIN=...]   Fill global.imageRegistry (from .env) and global.domain in VALUES_FILE"
	@echo "  make check-values PLATFORM=k8s|ocp  Verify VALUES_FILE has imageRegistry/domain/license.accept set"
	@echo "  make prereqs PLATFORM=k8s|ocp   Run all prerequisite steps for your platform"
	@echo "    make cert-manager-k8s / envoy-gateway-install / envoy-gateway-enable-backend   (k8s steps, individually)"
	@echo "    make cert-manager-ocp / wildcard-routes                                        (ocp steps, individually)"
	@echo "  make secrets                     Create namespace + registry/entitlement-key/WatsonX secrets from .env"
	@echo "  make wave0 / wave1 / wave2 / wave3   Run one chart wave"
	@echo "  make deploy PLATFORM=k8s|ocp     Run check-values + prereqs + secrets + all 4 waves in order"
	@echo "  make upgrade                     Re-apply wave 1 and wave 3 (see charts/idig/README.md Upgrading)"
	@echo "  make uninstall                   helm uninstall all 4 releases, reverse order"
	@echo "  make info PLATFORM=k8s|ocp       Print IDIG console + Dev Portal URLs and admin credentials"
	@echo ""
	@echo "Variables (override on the command line):"
	@echo "  NAMESPACE=$(NAMESPACE)"
	@echo "  VALUES_FILE=$(VALUES_FILE)"
	@echo "  PLATFORM=$(PLATFORM) (required for prereqs/deploy: k8s or ocp)"
	@echo "  DOMAIN=$(DOMAIN) (optional for fill-values; auto-detected on ocp if unset)"
	@echo "  CR_NAME=$(CR_NAME) (idigCluster.name -- only if you overrode it from the chart default)"

.PHONY: check-platform
check-platform:
	@if [ "$(PLATFORM)" != "k8s" ] && [ "$(PLATFORM)" != "ocp" ]; then \
		echo "✗ Set PLATFORM=k8s or PLATFORM=ocp explicitly." >&2; exit 1; \
	fi

# -----------------------------------------------------------------------------
# values.yaml: fill in + verify (edits $(VALUES_FILE) in place with yq)
# -----------------------------------------------------------------------------

.PHONY: fill-values
fill-values: check-platform
	@: $${REGISTRY_SERVER:?Set REGISTRY_SERVER in .env}
	@if [ -n "$(DOMAIN)" ]; then \
	  RESOLVED_DOMAIN="$(DOMAIN)"; \
	elif [ "$(PLATFORM)" = "ocp" ]; then \
	  RESOLVED_DOMAIN=$$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null); \
	  if [ -z "$$RESOLVED_DOMAIN" ]; then \
	    echo "✗ Could not auto-detect the cluster domain via 'oc get ingresses.config/cluster'. Set DOMAIN=... explicitly." >&2; exit 1; \
	  fi; \
	  echo "✓ Auto-detected domain from cluster: $$RESOLVED_DOMAIN"; \
	else \
	  echo "✗ DOMAIN is not set and PLATFORM=k8s has no reliable auto-detection. Set DOMAIN=apps.<your-cluster-domain> explicitly." >&2; exit 1; \
	fi; \
	CLEAN_REGISTRY=$$(printf '%s' "$$REGISTRY_SERVER" | sed -e 's/^"//' -e 's/"$$//'); \
	if [ "$(PLATFORM)" = "ocp" ]; then ENVOY_ENABLED=false; else ENVOY_ENABLED=true; fi; \
	CLEAN_REGISTRY="$$CLEAN_REGISTRY" yq eval -i '.global.imageRegistry = strenv(CLEAN_REGISTRY)' $(VALUES_FILE) && \
	yq eval -i ".global.domain = \"$$RESOLVED_DOMAIN\"" $(VALUES_FILE) && \
	yq eval -i ".envoyGateway.enabled = $$ENVOY_ENABLED" $(VALUES_FILE) && \
	echo "✓ Filled global.imageRegistry, global.domain, and envoyGateway.enabled=$$ENVOY_ENABLED in $(VALUES_FILE)." || \
	{ echo "✗ fill-values failed -- $(VALUES_FILE) may be partially updated, check it before proceeding." >&2; exit 1; }

.PHONY: check-values
check-values: check-platform
	@REGISTRY=$$(yq eval '.global.imageRegistry' $(VALUES_FILE)); \
	DOMAIN_VAL=$$(yq eval '.global.domain' $(VALUES_FILE)); \
	ACCEPT=$$(yq eval '.global.license.accept' $(VALUES_FILE)); \
	ENVOY_ENABLED=$$(yq eval '.envoyGateway.enabled' $(VALUES_FILE)); \
	FAIL=0; \
	[ -z "$$REGISTRY" ] || [ "$$REGISTRY" = "null" ] && { echo "✗ global.imageRegistry is empty in $(VALUES_FILE)." >&2; FAIL=1; }; \
	[ -z "$$DOMAIN_VAL" ] || [ "$$DOMAIN_VAL" = "null" ] && { echo "✗ global.domain is empty in $(VALUES_FILE)." >&2; FAIL=1; }; \
	[ "$$ACCEPT" != "true" ] && { echo "✗ global.license.accept is not 'true' in $(VALUES_FILE)." >&2; FAIL=1; }; \
	if [ "$(PLATFORM)" = "ocp" ] && [ "$$ENVOY_ENABLED" != "false" ]; then \
	  echo "✗ PLATFORM=ocp but envoyGateway.enabled is not 'false' in $(VALUES_FILE) -- Envoy Gateway/Gateway API has no OpenShift equivalent, wave0 would try to create an EnvoyProxy CR with no CRD for it. Run 'make fill-values PLATFORM=ocp' or set it manually." >&2; FAIL=1; \
	fi; \
	if [ "$(PLATFORM)" = "k8s" ] && [ "$$ENVOY_ENABLED" != "true" ]; then \
	  echo "✗ PLATFORM=k8s but envoyGateway.enabled is not 'true' in $(VALUES_FILE) -- wave0 needs it to create the EnvoyProxy/GatewayClass IDIG requires on Kubernetes. Run 'make fill-values PLATFORM=k8s' or set it manually." >&2; FAIL=1; \
	fi; \
	[ "$$FAIL" = "1" ] && exit 1; \
	echo "✓ check-values OK: $(VALUES_FILE) has imageRegistry, domain, license.accept, and envoyGateway.enabled consistent with PLATFORM=$(PLATFORM)."

# -----------------------------------------------------------------------------
# Prerequisites (charts/idig/README.md "Prerequisites")
# Each step is its own goal, runnable/testable in isolation. prereqs-k8s and
# prereqs-ocp are pure orchestrators listing which steps apply per platform.
# -----------------------------------------------------------------------------

.PHONY: prereqs
prereqs: check-platform
ifeq ($(PLATFORM),k8s)
	@$(MAKE) prereqs-k8s
else
	@$(MAKE) prereqs-ocp
endif

.PHONY: prereqs-k8s
prereqs-k8s: cert-manager-k8s envoy-gateway-install envoy-gateway-enable-backend

.PHONY: prereqs-ocp
prereqs-ocp: cert-manager-ocp wildcard-routes

.PHONY: cert-manager-k8s
cert-manager-k8s:
	@echo "▶ cert-manager"
	kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.20.3/cert-manager.yaml
	kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=cert-manager -n cert-manager --timeout=180s

.PHONY: envoy-gateway-install
envoy-gateway-install:
	@echo "▶ Envoy Gateway v1.7.0"
	kubectl apply --force-conflicts --server-side \
	  -f https://github.com/envoyproxy/gateway/releases/download/v1.7.0/install.yaml
	kubectl wait --timeout=300s --for=condition=available \
	  deployment/envoy-gateway -n envoy-gateway-system

.PHONY: envoy-gateway-enable-backend
envoy-gateway-enable-backend:
	@echo "▶ Enabling Envoy Gateway Backend CR support"
	@CURRENT=$$(kubectl get configmap envoy-gateway-config -n envoy-gateway-system \
	  -o jsonpath='{.data.envoy-gateway\.yaml}' | yq eval '.extensionApis.enableBackend' -); \
	if [ "$$CURRENT" = "true" ]; then \
	  echo "✓ Already enabled, nothing to do."; \
	else \
	  NEW_DATA=$$(kubectl get configmap envoy-gateway-config -n envoy-gateway-system \
	    -o jsonpath='{.data.envoy-gateway\.yaml}' \
	    | yq eval '.extensionApis.enableBackend = true' -); \
	  kubectl patch configmap envoy-gateway-config -n envoy-gateway-system \
	    --type=merge -p "$$(jq -n --arg v "$$NEW_DATA" '{data: {"envoy-gateway.yaml": $$v}}')"; \
	  kubectl rollout restart deployment envoy-gateway -n envoy-gateway-system; \
	  kubectl rollout status deployment envoy-gateway -n envoy-gateway-system --timeout=120s; \
	  echo "✓ Backend CR support enabled."; \
	fi

.PHONY: cert-manager-ocp
cert-manager-ocp:
	@echo "▶ cert-manager Operator for Red Hat OpenShift (OLM)"
	oc apply -f hack/cert-manager-ocp-subscription.yaml
	@echo "⏳ Waiting for the CSV to reach Succeeded (see charts/idig/README.md's OperatorDependencyNotInstalled note on failure)"
	@for i in $$(seq 1 30); do \
	  phase=$$(oc get csv -n cert-manager-operator -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo ""); \
	  if [ "$$phase" = "Succeeded" ]; then echo "✓ CSV Succeeded"; break; fi; \
	  echo "  csv phase: $${phase:-<none yet>} ($$i/30)"; sleep 10; \
	  if [ "$$i" = "30" ]; then echo "✗ Timed out waiting for CSV Succeeded -- check 'oc get csv -n cert-manager-operator'." >&2; exit 1; fi; \
	done

.PHONY: wildcard-routes
wildcard-routes:
	@echo "▶ Enabling OpenShift wildcard routes (cluster-wide -- see charts/idig/README.md note)"
	oc patch ingresscontroller default -n openshift-ingress-operator \
	  --type=merge \
	  -p '{"spec":{"routeAdmission":{"wildcardPolicy":"WildcardsAllowed"}}}'
	@echo "⏳ Waiting for router pods to roll out with the new policy"
	@oc rollout status deployment/router-default -n openshift-ingress --timeout=180s
	@echo "✓ Wildcard routes enabled."

# -----------------------------------------------------------------------------
# Secrets (charts/idig/README.md "Prerequisites" -> Namespace/Registry/etc.)
# Values come from .env, never from Makefile variables or the command line.
# -----------------------------------------------------------------------------

.PHONY: secrets
secrets: namespace registry-secret entitlement-key-secret watsonx-secret

.PHONY: namespace
namespace:
	kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -

.PHONY: registry-secret
registry-secret:
	@: $${REGISTRY_SERVER:?Set REGISTRY_SERVER in .env}
	@: $${REGISTRY_USERNAME:?Set REGISTRY_USERNAME in .env}
	@: $${REGISTRY_PASSWORD:?Set REGISTRY_PASSWORD in .env}
	@STRIP='s/^"//; s/"$$//'; \
	kubectl create secret docker-registry idig-registry-secret \
	  --docker-server="$$(printf '%s' "$$REGISTRY_SERVER" | sed -e "$$STRIP")" \
	  --docker-username="$$(printf '%s' "$$REGISTRY_USERNAME" | sed -e "$$STRIP")" \
	  --docker-password="$$(printf '%s' "$$REGISTRY_PASSWORD" | sed -e "$$STRIP")" \
	  -n $(NAMESPACE) \
	  --dry-run=client -o yaml | kubectl apply -f -
	@echo "✓ idig-registry-secret created. Set global.imagePullSecret=idig-registry-secret in $(VALUES_FILE) if not already set."

.PHONY: entitlement-key-secret
entitlement-key-secret:
	@if [ -z "$${IBM_ENTITLEMENT_KEY:-}" ]; then \
	  echo "⊘ IBM_ENTITLEMENT_KEY not set in .env, skipping ibm-entitlement-key secret."; \
	else \
	  STRIP='s/^"//; s/"$$//'; \
	  kubectl create secret docker-registry ibm-entitlement-key \
	    --docker-server=cp.icr.io/cp/datapower \
	    --docker-username=cp \
	    --docker-password="$$(printf '%s' "$$IBM_ENTITLEMENT_KEY" | sed -e "$$STRIP")" \
	    -n $(NAMESPACE) \
	    --dry-run=client -o yaml | kubectl apply -f -; \
	  echo "✓ ibm-entitlement-key created."; \
	fi

.PHONY: watsonx-secret
watsonx-secret:
	@if [ -z "$${WATSONX_API_KEY:-}" ]; then \
	  echo "⊘ WATSONX_API_KEY not set in .env, skipping watsonx-credentials secret (GenAI service stays undeployed)."; \
	else \
	  STRIP='s/^"//; s/"$$//'; \
	  kubectl create secret generic watsonx-credentials \
	    --from-literal=WATSONX_API_KEY="$$(printf '%s' "$$WATSONX_API_KEY" | sed -e "$$STRIP")" \
	    --from-literal=WATSONX_PROJECT_ID="$$(printf '%s' "$$WATSONX_PROJECT_ID" | sed -e "$$STRIP")" \
	    -n $(NAMESPACE) \
	    --dry-run=client -o yaml | kubectl apply -f -; \
	  echo "✓ watsonx-credentials created."; \
	fi

# -----------------------------------------------------------------------------
# Waves (charts/idig/README.md "Deployment")
# -----------------------------------------------------------------------------

.PHONY: wave0
wave0:
	@echo "▶ Wave 0: PKI (cert-manager Issuer/CA/Certificates)"
	helm upgrade --install idig-prereqs $(CHART_DIR) -f $(VALUES_FILE) --set deployment.wave=0 -n $(NAMESPACE) --hide-notes
	kubectl wait certificate --all -n $(NAMESPACE) --for=condition=Ready --timeout=120s
	@echo "✓ Wave 0 complete."

.PHONY: wave1
wave1:
	@echo "▶ Wave 1: operators (APIC, NanoGateway, Valkey, IDIG NanoGateway, IDIG)"
	@VENDOR_ENABLED=$$(yq eval '."idig-crds-vendor".enabled' $(VALUES_FILE)); \
	if [ "$$VENDOR_ENABLED" != "false" ] && [ $$(oc get crd -o name 2>/dev/null | grep -c 'apiconnect\.ibm\.com') -eq 0 ]; then \
	  echo "⚠ idig-crds-vendor.enabled is not false in $(VALUES_FILE), but no apiconnect.ibm.com CRDs are on the cluster."; \
	  echo "  If idig-prereqs (wave0) was already installed with idig-crds-vendor.enabled=false, 'helm upgrade' will NOT retroactively apply the CRDs -- Helm only applies a chart's crds/ on first install (see README 'Notes on this chart's construction')."; \
	  echo "  Apply them manually before this wave's operators (ibm-apiconnect in particular) can start:"; \
	  echo "    oc apply --server-side --force-conflicts -f $(CHART_DIR)/charts/idig-crds-vendor/crds/apic-operator-crds.yaml"; \
	fi
	helm upgrade --install idig-operators $(CHART_DIR) -f $(VALUES_FILE) --set deployment.wave=1 -n $(NAMESPACE) --hide-notes
	kubectl -n $(NAMESPACE) rollout status deployment/ibm-apiconnect
	kubectl -n $(NAMESPACE) rollout status deployment/datapower-nano-operator
	kubectl -n $(NAMESPACE) rollout status deployment/valkey-operator
	kubectl -n $(NAMESPACE) rollout status deployment/idig-gw-operator
	kubectl -n $(NAMESPACE) rollout status deployment/idig-operator
	@echo "✓ Wave 1 complete."

.PHONY: wave2
wave2:
	@echo "▶ Wave 2: Valkey instance"
	helm upgrade --install idig-valkey $(CHART_DIR) -f $(VALUES_FILE) --set deployment.wave=2 -n $(NAMESPACE) --hide-notes
	kubectl -n $(NAMESPACE) wait --for=condition=ready pod -l app.kubernetes.io/name=valkey --timeout=300s
	@echo "✓ Wave 2 complete."

.PHONY: wave3
wave3:
	@echo "▶ Wave 3: IDIG cluster"
	helm upgrade --install idig-cluster $(CHART_DIR) -f $(VALUES_FILE) --set deployment.wave=3 -n $(NAMESPACE) --hide-notes
	@echo "⏳ Tracking rollout (can take up to 20 minutes) -- only prints when status changes; Ctrl-C to stop watching, the install itself keeps going:"
	@LAST=""; STALL=0; \
	for i in $$(seq 1 120); do \
	  phase=$$(kubectl get datapowerinteractgatewaycluster idig -n $(NAMESPACE) -o jsonpath='{.status.phase}' 2>/dev/null || echo ""); \
	  detail=$$(kubectl get datapowerinteractgatewaycluster idig -n $(NAMESPACE) -o jsonpath='{.status.conditions[?(@.type=="IDIGComponentsPending")].message}' 2>/dev/null || echo ""); \
	  current="$$phase|$$detail"; \
	  if [ "$$phase" = "Ready" ]; then \
	    echo "✓ phase: Ready"; break; \
	  elif [ "$$current" != "$$LAST" ]; then \
	    echo "  phase: $${phase:-<none yet>}$${detail:+ -- $$detail}"; \
	    LAST="$$current"; STALL=0; \
	  else \
	    STALL=$$((STALL + 1)); \
	    if [ "$$STALL" -ge 30 ]; then \
	      echo "⚠ No change in 5 minutes, still: $${phase:-<none yet>}$${detail:+ -- $$detail}"; \
	      echo "  Check directly: kubectl describe datapowerinteractgatewaycluster idig -n $(NAMESPACE)"; \
	      STALL=0; \
	    fi; \
	  fi; \
	  if [ "$$i" = "120" ]; then \
	    echo "✗ Timed out after 20 minutes, still: $${phase:-<none yet>}$${detail:+ -- $$detail}" >&2; \
	    echo "  Check directly: kubectl describe datapowerinteractgatewaycluster idig -n $(NAMESPACE)" >&2; \
	    exit 1; \
	  fi; \
	  sleep 10; \
	done
	@echo "✓ Wave 3 complete."

.PHONY: deploy
deploy: check-platform check-values prereqs secrets wave0 wave1 wave2 wave3
	@echo "✓ Deployment complete. See charts/idig/README.md 'Accessing the IDIG user interfaces'."

.PHONY: upgrade
upgrade: wave1 wave3

.PHONY: uninstall
uninstall:
	helm uninstall idig-cluster -n $(NAMESPACE) || true
	helm uninstall idig-valkey -n $(NAMESPACE) || true
	helm uninstall idig-operators -n $(NAMESPACE) || true
	helm uninstall idig-prereqs -n $(NAMESPACE) || true

# -----------------------------------------------------------------------------
# info: URLs + admin credentials for the IDIG console and Dev Portal
# (see charts/idig/README.md "Accessing the IDIG user interfaces")
# -----------------------------------------------------------------------------

.PHONY: info
info: check-platform
	@echo "▶ IDIG console"; \
	if [ "$(PLATFORM)" = "ocp" ]; then \
	  CONSOLE_HOST=$$(kubectl get route $(CR_NAME)-idig-web -n $(NAMESPACE) -o jsonpath='{.spec.host}' 2>/dev/null); \
	else \
	  CONSOLE_HOST=$$(kubectl get httproute $(CR_NAME)-web -n $(NAMESPACE) -o jsonpath='{.spec.hostnames[0]}' 2>/dev/null); \
	fi; \
	if [ -z "$$CONSOLE_HOST" ]; then \
	  echo "  ✗ Not found -- is deployment.wave=3 (or all) deployed? (CR_NAME=$(CR_NAME))"; \
	else \
	  echo "  URL:      https://$$CONSOLE_HOST"; \
	  echo "  Username: administrator"; \
	  PASS=$$(kubectl get secret $(CR_NAME)-idig-admin-pass -n $(NAMESPACE) -o jsonpath='{.data.password}' 2>/dev/null | base64 -d); \
	  if [ -z "$$PASS" ]; then echo "  Password: ✗ secret $(CR_NAME)-idig-admin-pass not found"; \
	  else echo "  Password: $$PASS"; fi; \
	fi; \
	echo ""; \
	echo "▶ Developer Portal"; \
	if [ "$(PLATFORM)" = "ocp" ]; then \
	  DEVPORTAL_HOST=$$(kubectl get route $(CR_NAME)-devportal-devportal-web -n $(NAMESPACE) -o jsonpath='{.spec.host}' 2>/dev/null); \
	else \
	  DEVPORTAL_HOST=$$(kubectl get httproute $(CR_NAME)-devportal-devportal-web -n $(NAMESPACE) -o jsonpath='{.spec.hostnames[0]}' 2>/dev/null); \
	fi; \
	if [ -z "$$DEVPORTAL_HOST" ]; then \
	  echo "  (not found -- only present if idigCluster.enableDevPortal=true)"; \
	else \
	  echo "  URL:      https://$$DEVPORTAL_HOST"; \
	  echo "  Username: administrator"; \
	  PASS=$$(kubectl get secret $(CR_NAME)-devportal-admin-secret -n $(NAMESPACE) -o jsonpath='{.data.password}' 2>/dev/null | base64 -d); \
	  if [ -z "$$PASS" ]; then echo "  Password: ✗ secret $(CR_NAME)-devportal-admin-secret not found"; \
	  else echo "  Password: $$PASS"; fi; \
	fi; \
	echo ""
