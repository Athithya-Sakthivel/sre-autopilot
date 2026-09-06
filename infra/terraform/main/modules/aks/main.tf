# ============================================================================
# modules/aks/main.tf
#
# AKS cluster, managed identities, networking, and RBAC.
#
# Design:
# - User-assigned control-plane managed identity.
# - Azure CNI Overlay with Cilium eBPF dataplane/network policy.
# - User-assigned NAT Gateway attached to the supplied AKS subnet.
# - Azure Workload Identity with OIDC issuer enabled.
# - AcrPull granted to the AKS kubelet identity at ACR scope.
#
# Idempotency:
# - AKS default node-pool upgrade settings are declared explicitly.
# - max_surge matches the value currently returned by the AKS API.
# - drain_timeout_in_minutes and node_soak_duration_in_minutes are omitted
#   because the AKS API currently returns them as null for this node pool.
# - node_count and os_disk_size_gb are managed by OpenTofu and are not
#   ignored.
#
# API server access:
# API server authorized IP ranges are configured outside OpenTofu using
# Azure CLI because the current implementation uses the AzureCloud service
# tag, which is not represented by the authorized_ip_ranges argument.
# api_server_access_profile is therefore intentionally ignored to prevent
# OpenTofu from reverting that externally managed configuration.
# ============================================================================

resource "azurerm_user_assigned_identity" "aks" {
  name                = "${var.cluster_name}-identity"
  resource_group_name = var.resource_group_name
  location            = var.location

  tags = var.tags
}

resource "azurerm_role_assignment" "network_contributor" {
  scope                = var.aks_subnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks.principal_id
}

resource "azurerm_role_assignment" "acr_pull" {
  scope                = var.acr_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
}

# ----------------------------------------------------------------------------
# User Assigned Managed Identity for External Secrets Operator
# (Azure Workload Identity)
# ----------------------------------------------------------------------------

resource "azurerm_user_assigned_identity" "eso" {
  count = var.eso_identity_name != null ? 1 : 0

  name                = var.eso_identity_name
  resource_group_name = var.resource_group_name
  location            = var.location

  tags = var.tags
}

# ----------------------------------------------------------------------------
# Federated Identity Credential
# ----------------------------------------------------------------------------

resource "azurerm_federated_identity_credential" "eso" {
  count = var.eso_identity_name != null ? 1 : 0

  name                      = "eso-workload-identity"
  user_assigned_identity_id = azurerm_user_assigned_identity.eso[0].id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = azurerm_kubernetes_cluster.this.oidc_issuer_url
  subject                   = "system:serviceaccount:${var.eso_service_account_namespace}:${var.eso_service_account_name}"
}

# ----------------------------------------------------------------------------
# AKS Cluster
# ----------------------------------------------------------------------------

resource "azurerm_kubernetes_cluster" "this" {
  name                = var.cluster_name
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = var.cluster_name
  kubernetes_version  = var.kubernetes_version

  # Let OpenTofu explicitly control node-pool provisioning.
  node_provisioning_profile {
    mode = "Manual"
  }

  default_node_pool {
    name                 = "default"
    vm_size              = var.vm_size
    node_count           = var.node_count
    auto_scaling_enabled = false
    os_disk_size_gb      = var.os_disk_size_gb
    os_sku               = "AzureLinux3"
    vnet_subnet_id       = var.aks_subnet_id

    # Match the value currently returned by the AKS API.
    #
    # The current API response is:
    #   maxSurge = "10%"
    #   drainTimeoutInMinutes = null
    #   nodeSoakDurationInMinutes = null
    #   undrainableNodeBehavior = null
    #
    # Therefore only max_surge is declared here.
    upgrade_settings {
      max_surge = "10%"
    }
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aks.id]
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_policy      = "cilium"
    network_data_plane  = "cilium"

    outbound_type     = "userAssignedNATGateway"
    load_balancer_sku = "standard"

    service_cidr   = var.service_cidr
    dns_service_ip = var.dns_service_ip
    pod_cidr       = var.pod_cidr
  }

  workload_identity_enabled = true
  oidc_issuer_enabled       = true

  tags = var.tags

  depends_on = [
    azurerm_role_assignment.network_contributor
  ]

  lifecycle {
    # API server access settings are intentionally managed externally
    # through Azure CLI because the external configuration uses an Azure
    # service tag for authorized access.
    ignore_changes = [
      api_server_access_profile,
    ]
  }
}
