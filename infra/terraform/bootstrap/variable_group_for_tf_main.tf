# ------------------------------------------------------------------------------
# Variable group for terraform-ci / terraform-cd and application CD pipelines.
#
# Holds non-secret Terraform variables, Azure DevOps credentials, and the
# derived Azure infrastructure names needed by backend/frontend CD pipelines.
#
# All infrastructure names are derived using the SAME abbreviations as
# infra/terraform/main/locals.tf:
#   - environment "staging" -> "stg"
#   - environment "prod"     -> "prod"
#   - subscription suffix    -> last 6 characters
#
# This prevents CI/CD from referencing wrong ACR/AKS names after bootstrap.
#
# Secrets are NOT stored here. They are kept in Azure Key Vault and fetched
# at runtime by the pipelines.
#
# Application Insights connection string is intentionally NOT managed here.
# It is written to Key Vault by the main run.sh after `tofu apply`.
# ------------------------------------------------------------------------------

locals {
  env_abbr     = var.environment == "staging" ? "stg" : "prod"
  sub_suffix   = substr(var.subscription_id, length(var.subscription_id) - 6, 6)
  project_abbr = "taskapi"
}

resource "azuredevops_variable_group" "terraform_vars" {
  project_id   = azuredevops_project.this.id
  name         = "terraform-vars"
  description  = "Common Terraform variables and Azure infrastructure names for CI/CD pipelines"
  allow_access = true

  # ---------------------------------------------------------------------------
  # Terraform owner tag
  # ---------------------------------------------------------------------------
  variable {
    name  = "TF_VAR_owner"
    value = var.owner
  }

  # ---------------------------------------------------------------------------
  # Terraform input variables (non-derivable or externally supplied)
  # ---------------------------------------------------------------------------
  variable {
    name  = "TF_VAR_location"
    value = var.location
  }

  variable {
    name  = "TF_VAR_alert_email_address"
    value = var.alert_email_address
  }

  variable {
    name  = "TF_VAR_DOMAIN"
    value = var.DOMAIN
  }

  # ---------------------------------------------------------------------------
  # Azure DevOps provider credentials used by main/run.sh
  # ---------------------------------------------------------------------------
  variable {
    name  = "AZDO_ORG_SERVICE_URL"
    value = var.AZDO_ORG_SERVICE_URL
  }

  # ---------------------------------------------------------------------------
  # Non-sensitive Cloudflare values
  # ---------------------------------------------------------------------------
  variable {
    name  = "TF_VAR_cloudflare_tunnel_name"
    value = var.cloudflare_tunnel_name
  }

  variable {
    name  = "TF_VAR_cloudflare_tunnel_id"
    value = var.cloudflare_tunnel_id
  }

  # ---------------------------------------------------------------------------
  # Key Vault name for AzureKeyVault@2 tasks
  # ---------------------------------------------------------------------------
  variable {
    name  = "KEY_VAULT_NAME"
    value = "kv-azdo-bootstrap-${local.sub_suffix}"
  }

  # ---------------------------------------------------------------------------
  # Azure Container Registry name used by CD pipelines
  # ---------------------------------------------------------------------------
  variable {
    name  = "containerRegistry"
    value = "acr${local.project_abbr}${local.env_abbr}${local.sub_suffix}"
  }

  # ---------------------------------------------------------------------------
  # AKS resource group and cluster name used by CD pipelines
  # ---------------------------------------------------------------------------
  variable {
    name  = "aksResourceGroup"
    value = "rg-${local.project_abbr}-${local.env_abbr}"
  }

  variable {
    name  = "aksClusterName"
    value = "aks-${local.project_abbr}-${local.env_abbr}-${local.sub_suffix}"
  }

  # ---------------------------------------------------------------------------
  # The variable group now contains:
  #   - Terraform inputs
  #   - Azure DevOps provider URL
  #   - Key Vault name
  #   - ACR / AKS names
  #
  # All ACR/AKS/resource-group names now match infra/terraform/main/locals.tf.
  #
  # Secrets such as azdo-pat, database credentials, and Application Insights
  # connection string are fetched from Key Vault using AzureKeyVault@2.
  # ---------------------------------------------------------------------------
}
