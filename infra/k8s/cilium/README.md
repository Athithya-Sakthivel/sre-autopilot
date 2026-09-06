# Cilium NetworkPolicy Chart

This Helm chart manages Cilium Network Policies for the Task API platform. It does **not** install Cilium or manage Gateway/HTTPRoute resources. Gateway API is provided by Envoy Gateway.

## Directory Structure

```sh
infra/k8s/cilium
├── Chart.yaml
├── values.yaml
└── templates/
    └── networkpolicies/
        ├── networkpolicy-default-deny.yaml
        ├── networkpolicy-dns.yaml
        ├── networkpolicy-cloudflared-egress.yaml
        ├── networkpolicy-cloudflared-to-frontend.yaml
        ├── networkpolicy-gateway-to-frontend.yaml
        ├── networkpolicy-frontend-to-backend.yaml
        └── networkpolicy-backend-to-postgres.yaml
```

## Prerequisites

- Cilium CNI installed (either standalone on kind or Azure CNI Powered by Cilium on AKS)
- Envoy Gateway installed as the Gateway API controller
- GatewayClass `eg` created (by Envoy Gateway)
- Namespaces `gateway`, `task-api`, `cloudflared` created
- Argo Rollouts Gateway API plugin configured (for canary deployments)

## What This Chart Creates

### CiliumNetworkPolicies

- `default-deny` – deny all ingress/egress for `task-api` pods.
- `allow-task-api-dns` – allow DNS queries to CoreDNS.
- `allow-cloudflared-egress` – allow Cloudflared pods to reach DNS, Cloudflare Tunnel endpoints (UDP/TCP 7844), and HTTPS (TCP 443).
- `allow-cloudflared-to-frontend` – allow Cloudflared pods to reach frontend pods on TCP 8080.
- `allow-gateway-to-frontend` – allow Envoy Gateway ingress to frontend pods on port 8080.
- `allow-frontend-to-backend` – allow frontend pods to connect to backend pods on port 8080.
- `allow-backend-to-postgres` – allow backend pods to connect to PostgreSQL pods on port 5432.

## Installation

```bash
helm upgrade --install cilium infra/k8s/cilium \
  --namespace gateway \
  --create-namespace
```

## Configuration

Key values (see `values.yaml` for full list):

| Value                                   | Default | Description                             |
| --------------------------------------- | ------- | --------------------------------------- |
| `networkPolicies.enabled`               | `true`  | Enable all network policies             |
| `networkPolicies.defaultDeny`           | `true`  | Enable default-deny policy              |
| `networkPolicies.dnsEgress`             | `true`  | Allow DNS for task-api pods             |
| `networkPolicies.cloudflaredEgress`     | `true`  | Allow Cloudflared outbound connectivity |
| `networkPolicies.cloudflaredToFrontend` | `true`  | Allow Cloudflared to reach frontend     |
| `networkPolicies.gatewayToFrontend`     | `true`  | Allow Envoy Gateway to reach frontend   |

## HTTPRoutes

HTTPRoutes are **not** created by this chart. They are managed by the deployment scripts (`backend-deploy.sh`, `frontend-deploy.sh`) using the Argo Rollouts Gateway API plugin. The initial weights (stable: 100%, canary: 0%) are set by those scripts and adjusted during rollouts.

## Uninstall

```bash
helm uninstall cilium -n gateway
```

## Security Notes

- The `CiliumNetworkPolicy` for Cloudflared allows DNS, Cloudflare Tunnel transport, and application traffic to frontend pods on TCP 8080.
- With Envoy Gateway, traffic from the Gateway to frontend pods originates from Envoy pods in the `envoy-gateway-system` namespace. The `allow-gateway-to-frontend` policy may need to be updated to allow that source explicitly. Verify after deployment.
- Default-deny policies require explicit DNS allowance (included).

## Dependencies

- Cilium CNI (v1.19.6+ or Azure CNI Powered by Cilium)
- Envoy Gateway (v1.9.1+)
- Gateway API CRDs (v1.6.1)
- Argo Rollouts (for HTTPRoute management)
- External Secrets Operator (for `backend-secrets`) – but not required by this chart.
