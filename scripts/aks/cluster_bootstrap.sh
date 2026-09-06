#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# AKS Cluster Bootstrap – Full platform setup
#
# Components installed:
#   - Envoy Gateway (Gateway API)
#   - Argo Rollouts (with Gateway API traffic router plugin)
#   - External Secrets Operator (Workload Identity + Azure Key Vault)
#   - Cloudflared (Cloudflare Tunnel)
#
# Assumes:
#   - az login already completed
#   - Terraform/OpenTofu already applied the infra/terraform/main infrastructure
#   - kubectl, helm, jq, az, curl are installed
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
TERRAFORM_DIR="$REPO_ROOT/infra/terraform/main"

# -----------------------------------------------------------------------------
# Versions
# -----------------------------------------------------------------------------
ENVOY_GATEWAY_VERSION="${ENVOY_GATEWAY_VERSION:-v1.9.1}"
ARGO_ROLLOUTS_VERSION="${ARGO_ROLLOUTS_VERSION:-v1.9.1}"
ARGO_ROLLOUTS_CHART_VERSION="${ARGO_ROLLOUTS_CHART_VERSION:-2.41.1}"
GATEWAY_API_PLUGIN_VERSION="${GATEWAY_API_PLUGIN_VERSION:-v0.16.0}"
ESO_VERSION="${ESO_VERSION:-2.8.0}"

# -----------------------------------------------------------------------------
# Namespaces
# -----------------------------------------------------------------------------
ENVOY_GATEWAY_NS="${ENVOY_GATEWAY_NS:-envoy-gateway-system}"
ARGO_NS="${ARGO_NS:-argo-rollouts}"
ESO_NS="${ESO_NS:-external-secrets}"
GATEWAY_NS="${GATEWAY_NS:-gateway}"
APP_NS="${APP_NS:-task-api}"
CLOUDFLARED_NS="${CLOUDFLARED_NS:-cloudflared}"

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
log()   { printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
fail()  { log "ERROR: $*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

require_cmd az
require_cmd kubectl
require_cmd helm
require_cmd jq
require_cmd curl

# -----------------------------------------------------------------------------
# Resolve Azure context and cluster details dynamically
# -----------------------------------------------------------------------------
log "Resolving Azure subscription and AKS cluster from Terraform outputs..."

AZURE_SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
[[ -n "$AZURE_SUBSCRIPTION_ID" ]] || fail "Unable to determine current Azure subscription."

cd "$TERRAFORM_DIR"
RESOURCE_GROUP_NAME="$(tofu output -raw resource_group_name 2>/dev/null || true)"
AKS_CLUSTER_NAME="$(tofu output -raw aks_cluster_name 2>/dev/null || true)"
if [[ -z "$RESOURCE_GROUP_NAME" || -z "$AKS_CLUSTER_NAME" ]]; then
  log "Terraform outputs not available; falling back to az aks list"
  AKS_CLUSTER_JSON="$(az aks list --query "[?tags.project=='task-api' && tags.environment=='staging'] | [0]" -o json 2>/dev/null || true)"
  if [[ -z "$AKS_CLUSTER_JSON" || "$AKS_CLUSTER_JSON" == "null" ]]; then
    fail "No AKS cluster found for task-api/staging."
  fi
  AKS_CLUSTER_NAME="$(jq -r '.name' <<<"$AKS_CLUSTER_JSON")"
  RESOURCE_GROUP_NAME="$(jq -r '.resourceGroup' <<<"$AKS_CLUSTER_JSON")"
fi
cd "$REPO_ROOT"

log "Subscription: $AZURE_SUBSCRIPTION_ID"
log "Resource Group: $RESOURCE_GROUP_NAME"
log "AKS Cluster: $AKS_CLUSTER_NAME"

# -----------------------------------------------------------------------------
# Get AKS credentials
# -----------------------------------------------------------------------------
az aks get-credentials \
  --resource-group "$RESOURCE_GROUP_NAME" \
  --name "$AKS_CLUSTER_NAME" \
  --overwrite-existing

kubectl config use-context "$AKS_CLUSTER_NAME"

# -----------------------------------------------------------------------------
# Ensure current engineer's public IP is allowed to reach the AKS API
# -----------------------------------------------------------------------------
ensure_aks_access() {
  local rg="$1" cluster="$2"
  local current_ip existing_ranges new_ranges

  # Test if API is already reachable
  if kubectl get nodes --request-timeout=10s >/dev/null 2>&1; then
    log "AKS API is already accessible."
    return 0
  fi

  # Fetch current public IP
  current_ip="$(curl -4 -fsSL https://ifconfig.me 2>/dev/null || true)"
  if [[ -z "$current_ip" ]]; then
    log "WARN: cannot determine current public IP; assuming AKS API is accessible."
    return 0
  fi

  existing_ranges="$(az aks show --resource-group "$rg" --name "$cluster" \
    --query 'apiServerAccessProfile.authorizedIpRanges' -o tsv 2>/dev/null || true)"
  existing_ranges="${existing_ranges// /}"

  if [[ -z "$existing_ranges" ]]; then
    new_ranges="${current_ip}/32"
  elif [[ ",${existing_ranges}," == *",${current_ip}/32,"* ]]; then
    log "Current IP already in authorized ranges."
    return 0
  else
    new_ranges="${existing_ranges},${current_ip}/32"
  fi

  log "Adding current public IP ${current_ip}/32 to AKS authorized IP ranges..."
  az aks update --resource-group "$rg" --name "$cluster" \
    --api-server-authorized-ip-ranges "$new_ranges" \
    --output none || fail "Failed to update AKS authorized IP ranges"

  log "Waiting for authorized IP range propagation..."
  for i in $(seq 1 12); do
    sleep 10
    if kubectl get nodes --request-timeout=10s >/dev/null 2>&1; then
      log "AKS API is now accessible."
      return 0
    fi
  done
  fail "Timed out waiting for AKS API to become accessible."
}

ensure_aks_access "$RESOURCE_GROUP_NAME" "$AKS_CLUSTER_NAME"
kubectl cluster-info >/dev/null || fail "Cannot connect to AKS cluster."

# -----------------------------------------------------------------------------
# Clean up any previous incorrect Argo Rollouts install
# -----------------------------------------------------------------------------
log "Removing any previous Argo Rollouts in default namespace..."
kubectl delete deployment argo-rollouts -n default --ignore-not-found=true

# -----------------------------------------------------------------------------
# 1. Install Envoy Gateway
# -----------------------------------------------------------------------------
log "Installing Envoy Gateway ${ENVOY_GATEWAY_VERSION}..."

helm upgrade --install eg \
  oci://docker.io/envoyproxy/gateway-helm \
  --version "${ENVOY_GATEWAY_VERSION}" \
  --namespace "${ENVOY_GATEWAY_NS}" \
  --create-namespace \
  --wait \
  --timeout 5m

kubectl wait \
  --namespace "${ENVOY_GATEWAY_NS}" \
  --for=condition=Available \
  deployment/envoy-gateway \
  --timeout=5m

log "Envoy Gateway controller is Available."

# -----------------------------------------------------------------------------
# 2. Create GatewayClass and Gateway
# -----------------------------------------------------------------------------
log "Creating GatewayClass 'eg' and Gateway..."

kubectl create namespace "${GATEWAY_NS}" --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: gateway
  namespace: ${GATEWAY_NS}
spec:
  gatewayClassName: eg
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: Selector
          selector:
            matchLabels:
              gateway-access: "true"
EOF

kubectl wait --for=condition=Accepted gatewayclass/eg --timeout=120s
kubectl create namespace "${APP_NS}" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "${APP_NS}" gateway-access=true --overwrite

log "GatewayClass 'eg' accepted, application namespace labeled."

# -----------------------------------------------------------------------------
# 3. Install Argo Rollouts with Gateway API plugin
# -----------------------------------------------------------------------------
log "Installing Argo Rollouts ${ARGO_ROLLOUTS_VERSION} with Gateway API plugin..."

helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm repo update

cat > /tmp/argo-rollouts-values.yaml <<EOF
controller:
  image:
    registry: quay.io
    repository: argoproj/argo-rollouts
    tag: ${ARGO_ROLLOUTS_VERSION}
  initContainers:
    - name: copy-gateway-api-plugin
      image: ghcr.io/argoproj-labs/rollouts-plugin-trafficrouter-gatewayapi:${GATEWAY_API_PLUGIN_VERSION}
      imagePullPolicy: IfNotPresent
      command:
        - /bin/sh
        - -c
      args:
        - cp /bin/rollouts-plugin-trafficrouter-gatewayapi /plugins/rollouts-plugin-trafficrouter-gatewayapi
      volumeMounts:
        - name: gateway-api-plugin
          mountPath: /plugins

  trafficRouterPlugins:
    - name: argoproj-labs/gatewayAPI
      location: file:///plugins/rollouts-plugin-trafficrouter-gatewayapi

  volumes:
    - name: gateway-api-plugin
      emptyDir: {}

  volumeMounts:
    - name: gateway-api-plugin
      mountPath: /plugins

providerRBAC:
  enabled: true
  providers:
    gatewayAPI: true
EOF

helm upgrade --install argo-rollouts argo/argo-rollouts \
  --namespace "${ARGO_NS}" \
  --create-namespace \
  --version "${ARGO_ROLLOUTS_CHART_VERSION}" \
  --values /tmp/argo-rollouts-values.yaml \
  --wait --timeout 5m

kubectl rollout status deployment/argo-rollouts -n "${ARGO_NS}" --timeout=5m

log "Argo Rollouts installed in ${ARGO_NS}."

# -----------------------------------------------------------------------------
# 4. Install External Secrets Operator (Workload Identity on AKS)
# -----------------------------------------------------------------------------
log "Installing External Secrets Operator ${ESO_VERSION}..."

helm repo add external-secrets https://charts.external-secrets.io
helm repo update

helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace "${ESO_NS}" \
  --create-namespace \
  --version "${ESO_VERSION}" \
  --wait --timeout 5m

kubectl rollout status deployment/external-secrets -n "${ESO_NS}" --timeout=5m

# Fetch ESO identity client ID and tenant ID
cd "$TERRAFORM_DIR"
eso_client_id="$(tofu output -raw eso_identity_client_id)"
cd "$REPO_ROOT"

[[ -n "$eso_client_id" ]] || fail "ESO identity client ID not found in Terraform outputs."

TENANT_ID="$(az account show --query tenantId -o tsv)"
[[ -n "$TENANT_ID" ]] || fail "Cannot determine tenant ID."

SUFFIX="${AZURE_SUBSCRIPTION_ID: -6}"
KEYVAULT_NAME="kv-azdo-bootstrap-${SUFFIX}"
KEYVAULT_URL="https://${KEYVAULT_NAME}.vault.azure.net"

log "Using ESO client ID: ${eso_client_id}"
log "Using tenant ID: ${TENANT_ID}"
log "Using Key Vault URL: ${KEYVAULT_URL}"

# Ensure target namespaces exist before ESO creates ExternalSecrets
kubectl create namespace "${CLOUDFLARED_NS}" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "${APP_NS}" --dry-run=client -o yaml | kubectl apply -f -

# Ensure ServiceAccount exists and is annotated for Workload Identity
kubectl create serviceaccount eso-azure-kv -n "${ESO_NS}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl annotate serviceaccount eso-azure-kv -n "${ESO_NS}" \
  azure.workload.identity/client-id="${eso_client_id}" \
  azure.workload.identity/tenant-id="${TENANT_ID}" \
  --overwrite

kubectl label serviceaccount eso-azure-kv -n "${ESO_NS}" \
  azure.workload.identity/use=true --overwrite

# Remove any previous manually created ClusterSecretStore
kubectl delete clustersecretstore azure-keyvault --ignore-not-found=true

# Install ESO config chart with Workload Identity overrides
log "Installing ESO config chart with Workload Identity overrides..."
helm upgrade --install eso-config "${REPO_ROOT}/infra/k8s/externalsecrets" \
  --namespace "${ESO_NS}" \
  --set keyVault.url="${KEYVAULT_URL}" \
  --set auth.mode=WorkloadIdentity \
  --set auth.workloadIdentity.serviceAccountName=eso-azure-kv \
  --set auth.workloadIdentity.serviceAccountNamespace="${ESO_NS}" \
  --set auth.workloadIdentity.createServiceAccount=false

# Wait for cloudflared-token Secret
log "Waiting for cloudflared-token Secret to be synced..."
for i in $(seq 1 60); do
  if kubectl get secret cloudflared-token -n "${CLOUDFLARED_NS}" >/dev/null 2>&1; then
    log "cloudflared-token Secret is available."
    break
  fi
  sleep 5
  if [[ $i == 60 ]]; then
    fail "Timed out waiting for cloudflared-token Secret."
  fi
done

# -----------------------------------------------------------------------------
# 5. Install Cloudflared
# -----------------------------------------------------------------------------
log "Installing Cloudflared..."
helm upgrade --install cloudflared "${REPO_ROOT}/infra/k8s/cloudflared" \
  --namespace "${CLOUDFLARED_NS}" \
  --create-namespace \
  --wait --timeout 5m

log "Cloudflared installed."

# -----------------------------------------------------------------------------
# 6. Wait for Gateway to be Programmed
# -----------------------------------------------------------------------------
log "Waiting for Gateway to become Programmed..."
kubectl wait --namespace "${GATEWAY_NS}" --for=condition=Programmed gateway/gateway --timeout=300s

log "AKS platform bootstrap complete."
log "Components ready:"
log "  - Envoy Gateway (GatewayClass eg)"
log "  - Argo Rollouts (Gateway API plugin)"
log "  - External Secrets Operator (Workload Identity + Azure Key Vault)"
log "  - Cloudflared"
log "Next steps: deploy backend and frontend using deployment scripts."
