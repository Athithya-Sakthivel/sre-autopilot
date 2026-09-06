#

# Step-by-Step Deployment Guide

## Prerequisites

1. **Docker installed and running _without_ sudo access (sudo usermod -aG docker $USER && newgrp docker)**
2. **Visual Studio Code with the Dev Containers extension installed (for a deterministic environments): [devcontainers](https://code.visualstudio.com/docs/devcontainers/containers)**
3. **An Azure subscription(Temporary resources, free tier or azure for students is sufficient)** with permissions to create:
   - **Azure Kubernetes Service (AKS)** (Compute cluster)
   - **Azure Monitor** (Application Insights & Log Analytics Workspace)
   - **Azure Storage Account** (Terraform State Backend + ACR)
   - **Key Vault** (Secrets Management)
   - **Identity & Access** (Microsoft Entra ID, SAMI, Workload Identity Federation, RBAC)
   - **Azure PostgreSQL for flexible server** (Postgres database for the application)
   - **Azure DevOps Organization** (CI/CD Orchestration)
4. **A Cloudflare account with a registered domain, with permissions to manage DNS records and create Cloudflare Tunnels (cloudflared)**

### PHASE 0.1: Clone the repo and build the devcontainer(Reproducible). This will take 10-20 minutes.

```sh
cd $HOME && rm -rf aks-canary-platform && git clone https://github.com/Athithya-Sakthivel/aks-canary-platform.git && cd aks-canary-platform && code .
```

> ctrl + shift + P -> paste `Dev containers: Rebuild Container Without Cache` and enter

### PHASE 0.2 Open a new terminal and login to your gh account

```sh
git config --global user.name "Your Name"
git config --global user.email you@example.com
gh auth login

? What account do you want to log into? GitHub.com
? What is your preferred protocol for Git operations? `SSH`
? Generate a new SSH key to add to your GitHub account? `No`
? How would you like to authenticate GitHub CLI? `Login with a web browser`

! First copy your one-time code: <code>
- Press Enter to open github.com in your browser...
✓ Authentication complete. Press Enter to continue...
```

---

### PHASE 0.3 Create a private repo in your gh account

```sh
export REPO_NAME="aks-canary-platform"
git remote remove origin 2>/dev/null || true
gh repo create "$REPO_NAME" --private >/dev/null 2>&1
REMOTE_URL="https://github.com/$(gh api user | jq -r .login)/$REPO_NAME.git"
git remote add origin "$REMOTE_URL" 2>/dev/null || true
git branch -M main 2>/dev/null || true
git push -u origin main
git pull
git remote -v
echo "[INFO] A private repo '$REPO_NAME' created and pushed. Only visible from your account."
```

---

### PHASE 0.4 Log in to azure and select the correct subscription

```bash
az login
```

<details>
<summary>▶ Expected output</summary>

![alt text](docs/screenshots/login.png)
</details>

---

## Getting Started

This guide walks through deploying the full platform on Azure, from edge networking to progressive canary releases.

### Prerequisites

Before starting, ensure the following tools are installed and configured:

- **Azure CLI** (`az`) — logged in with an active subscription.
- **OpenTofu** or **Terraform** (`tofu` / `terraform`) — version `>=1.12.0`.
- **kubectl** — with access to the target Kubernetes cluster.
- **Helm** (`helm`) — version `3.x`.
- **jq**, **curl**, **git**, **openssl** — standard utilities.
- **Cloudflare account** with a domain managed by Cloudflare.
- **GitHub account** with a personal access token (PAT) for Azure DevOps integration.
- **Azure DevOps organization** — created manually if not already available.

---

Here's a polished version of your documentation with corrected grammar, improved clarity, and consistent formatting. Each collapsible section is now standardized for easy screenshot insertion.

---

# Task API Canary Platform – Deployment Guide

## PHASE 1: Set Up All Cloud Infrastructure

### PHASE 1.1: Set Up Cloudflare Tunnel for Edge Access and DNS

Creates DNS records and a Cloudflare Tunnel that securely routes traffic to the cluster — no load balancers or public IPs needed. A Global API Key is required once for simplified automation. The script waits for you to authorize the Cloudflare Tunnel with your domain.

```sh
export CLOUDFLARE_ACCOUNT_ID=   # https://dash.cloudflare.com/profile/api-tokens > API Keys
export CLOUDFLARE_GLOBAL_API_KEY= # Cloudflare dashboard > Account Home > Search and enter "Copy account ID".
export CLOUDFLARE_EMAIL=       # example: "athithya651@gmail.com"
export DOMAIN=                 # example: "athithya.site"
bash infra/terraform/edge/run.sh --apply
```

<details>
<summary>▶ Expected output</summary>

<!-- Insert screenshot: Cloudflare login, domain authorization, edge Terraform outputs -->

</details>

---

### PHASE 1.2: Azure DevOps Organization Setup (Manual, No API Automation Available)

If you do not already have an Azure DevOps organization, create one via the [official guide](https://learn.microsoft.com/en-in/azure/devops/organizations/accounts/create-organization?view=azure-devops#create-an-organization-1). Automated organization creation is unsupported; all organizations must be created manually through the web portal.

Microsoft recommends using GitHub as the primary repository and source of truth for source code instead of Azure Repos, with Azure DevOps focused on CI/CD orchestration. This guide follows that recommended approach.

<details>
<summary>▶ Expected output</summary>

<!-- Insert screenshot: Azure DevOps organization / PAT creation -->

</details>

---

### PHASE 1.3: Bootstrap Azure DevOps, Terraform Remote Backend, and Secrets (One‑Time, Locally)

This script provisions the Terraform state backend and bootstraps Azure DevOps (project, GitHub service connection, OIDC federation, service connections, and a security scan pipeline). Upon success, it triggers the Terraform CI pipeline and outputs the pipeline URLs. This process is idempotent. The bootstrap provisions Workload Identity Federation (WIF) so downstream CI/CD pipelines authenticate via OIDC — no stored secrets, no certificates, no rotation.

```bash
# One-time secrets
export TF_VAR_AZDO_ORG_SERVICE_URL="https://dev.azure.com/<organization_name>"
export TF_VAR_AZDO_GITHUB_SERVICE_CONNECTION_PAT="<github-pat>" # Generate at https://github.com/settings/tokens/new

# Azure DevOps variable group entries
export TF_VAR_location=centralindia          # Azure service tags for Azure DevOps and AKS authentication verified available in centralindia
export TF_VAR_alert_email_address=           # example: athithya651@gmail.com
export TF_VAR_DOMAIN=                        # example: athithya.site
export TF_VAR_owner=                         # any username for tags

# Key Vault secrets (non-derivable secrets)
export TF_VAR_AZDO_PERSONAL_ACCESS_TOKEN="<azure-devops-pat>"   # Generate at https://dev.azure.com/<organization_name>/_usersSettings/tokens

bash infra/terraform/bootstrap/bootstrap.sh --create
sleep 5
git add . && git commit -m "bootstrap extend" && git push origin main
```

<details>
<summary>▶ Expected output</summary>

<!-- Insert screenshot: bootstrap script success, pipeline URLs -->

</details>

---

### PHASE 1.4: Apply Main Azure Infrastructure

Trigger the Terraform CD pipeline manually from the Azure DevOps UI. It provisions all Azure resources for staging. Unlike other CD pipelines, Terraform CD is run manually because human-in-the-loop (HITL) is critical for cloud provisioning.

**Pipeline:** `aks-canary-platform-terraform-cd`
**Branch:** `main`

<details>
<summary>▶ Expected output</summary>

<!-- Insert screenshot: Terraform CD pipeline run success -->

</details>

---

## PHASE 2: Perform Canary Deployment

### PHASE 2.1: Trigger Stable Deployment

Make changes to the frontend and backend code directories to trigger the `frontend-ci` and `backend-ci` pipelines. On successful completion, they automatically trigger the `frontend-cd` and `backend-cd` pipelines to deploy the stable rollout.

```sh
echo "--" >> services/backend/src/trigger.txt
echo "--" >> services/frontend/src/trigger.txt
git add services && git commit -m "Trigger app CI/CD pipelines for stable deployment" && git push origin main
```

<details>
<summary>▶ Expected output</summary>

<!-- Insert screenshot: CI/CD pipeline success, stable rollout healthy -->

</details>

---

### PHASE 2.2: Trigger Backend Canary Deployment

Make new changes to create a new image SHA so the Azure DevOps pipeline performs a canary deployment instead of a stable release.Once the canary succeeds for the backend service, the previous ReplicaSet is scaled down by Argo Rollouts. The HPA, which targets the Argo Rollout, automatically manages scaling for the active version. HPA should be applied to both frontend and backend Rollouts.

```sh
echo "--" >> services/backend/src/trigger.txt
git add . && git commit -m "Trigger app CI/CD pipelines for canary deployment" && git push origin main
```

Open a terminal and run the following to watch the canary live:

```bash
kubectl argo rollouts get rollout backend -n task-api -w
```

<details>
<summary>▶ Expected output</summary>

<!-- Insert screenshot: Argo Rollouts canary progression, traffic split, HPA scaling -->

</details>

---

### PHASE 2.3 (Optional): Trigger Frontend Canary Deployment

```sh
echo "--" >> services/frontend/src/trigger.txt
git add . && git commit -m "Trigger frontend CI/CD pipelines for canary deployment" && git push origin main
```

Open a terminal and run:

```bash
kubectl argo rollouts get rollout frontend -n task-api -w
```

<details>
<summary>▶ Expected output</summary>

<!-- Insert screenshot: frontend canary progression -->

</details>

---

# PHASE 3 validate everything

## PHASE 3.1 Observability

All deployments are monitored through **Azure Monitor Workbooks**, deployed automatically by Terraform. Four dashboards cover the platform's key signals:

- **Application SLO** – availability, latency, traffic, error rate, and business metrics.
- **Infrastructure** – AKS node saturation and API server errors.
- **Database** – PostgreSQL connections, CPU, and storage health.
- **Canary Release** – stable vs. canary comparison of error rate, latency, and traffic split.

### Access the Dashboards

1. Open the [Azure Portal](https://portal.azure.com) in your browser.
2. Navigate to the resource group **`rg-taskapi-stg`**.
3. Select the workbook you want to open, for example **Task API Canary Release**.
4. Click **Open Workbook** to view the dashboard.

<details>
<summary>▶ Expected outputs</summary>

<!-- Insert screenshot: workbook URLs output -->

</details>

### PHASE 3.2 Open the app.<domain> in browser and register as new user and then create a simple task

<details>
<summary>▶ Expected outputs</summary>

</details>

---

## Cleanup

To destroy all infrastructure:

```bash
bash infra/terraform/edge/run.sh --destroy
export TF_BACKEND_AUTH_MODE=cli
bash infra/terraform/main/run.sh --destroy --env staging --yes-delete
bash infra/terraform/bootstrap/bootstrap.sh --delete --force
```

Then manually delete the Azure DevOps organization if no longer needed.

---
