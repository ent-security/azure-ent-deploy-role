data "azurerm_subscription" "current" {}
data "azuread_client_config" "current" {}

# -----------------------------------------------------------------------------
# Resource Provider Registration
#
# Ensures all Azure resource providers required by the Ent platform are
# registered on this subscription. Registration is idempotent — already-registered
# providers are a no-op. The customer/admin running this module has sufficient
# permissions; the deploy SP intentionally does not.
# -----------------------------------------------------------------------------

resource "azurerm_resource_provider_registration" "required" {
  for_each = toset([
    "Microsoft.ContainerService",
    "Microsoft.DBforPostgreSQL",
    "Microsoft.Cache",
    "Microsoft.ContainerRegistry",
    "Microsoft.ServiceBus",
    "Microsoft.Storage",
    "Microsoft.KeyVault",
    "Microsoft.Network",
    "Microsoft.ManagedIdentity",
    "Microsoft.Compute",
    "Microsoft.Resources",
  ])
  name = each.value
}

# -----------------------------------------------------------------------------
# Custom Role Definition: Scoped permissions for Ent Home deployment and runtime
#
# This role grants the minimum permissions needed for Ent Home to:
# 1. Deploy infrastructure via OpenTofu (AKS, PostgreSQL, Redis, Storage, etc.)
# 2. Copy container images to customer ACR
# 3. Run application workloads (Service Bus, Key Vault, Storage, etc.)
#
# Derived from the Azure resources in ent-platform/deploy/tofu/azure/platform/.
# -----------------------------------------------------------------------------

resource "azurerm_role_definition" "ent_deploy" {
  name        = var.role_name
  scope       = data.azurerm_subscription.current.id
  description = var.role_description

  permissions {
    actions = [

      # ── Resource Groups ───────────────────────────────────────────────
      "Microsoft.Resources/subscriptions/resourceGroups/read",
      "Microsoft.Resources/subscriptions/resourceGroups/write",
      "Microsoft.Resources/subscriptions/resourceGroups/delete",
      "Microsoft.Resources/deployments/*",

      # ── Networking (VNet, Subnets, NSG, NAT Gateway, Public IP) ──────
      "Microsoft.Network/virtualNetworks/*",
      "Microsoft.Network/networkSecurityGroups/*",
      "Microsoft.Network/natGateways/*",
      "Microsoft.Network/publicIPAddresses/*",
      "Microsoft.Network/privateEndpoints/*",
      "Microsoft.Network/privateDnsZones/*",

      # ── AKS ───────────────────────────────────────────────────────────
      "Microsoft.ContainerService/managedClusters/*",
      "Microsoft.ContainerService/locations/*",

      # ── Container Registry ────────────────────────────────────────────
      "Microsoft.ContainerRegistry/registries/*",
      "Microsoft.ContainerRegistry/locations/*",

      # ── PostgreSQL Flexible Server ────────────────────────────────────
      "Microsoft.DBforPostgreSQL/flexibleServers/*",
      "Microsoft.DBforPostgreSQL/locations/*",

      # ── Redis (Azure Managed Redis) ───────────────────────────────────
      "Microsoft.Cache/*",

      # ── Key Vault ─────────────────────────────────────────────────────
      "Microsoft.KeyVault/vaults/*",
      "Microsoft.KeyVault/locations/*",

      # ── Storage Accounts & Containers ─────────────────────────────────
      "Microsoft.Storage/storageAccounts/*",
      "Microsoft.Storage/locations/*",

      # ── Service Bus ───────────────────────────────────────────────────
      "Microsoft.ServiceBus/namespaces/*",
      "Microsoft.ServiceBus/locations/*",

      # ── DNS ───────────────────────────────────────────────────────────
      "Microsoft.Network/dnszones/*",

      # ── Managed Identity & RBAC ───────────────────────────────────────
      "Microsoft.ManagedIdentity/userAssignedIdentities/*",
      "Microsoft.Authorization/roleAssignments/*",
      "Microsoft.Authorization/roleDefinitions/read",

      # ── Provider Registration (for validation checks) ─────────────────
      "Microsoft.Resources/subscriptions/providers/read",

      # ── Compute (for SKU availability checks) ─────────────────────────
      "Microsoft.Compute/skus/read",
      "Microsoft.Compute/locations/*",

      # ── Monitoring ────────────────────────────────────────────────────
      "Microsoft.Insights/*",
      "Microsoft.OperationalInsights/*",

      # ── Tagging ───────────────────────────────────────────────────────
      "Microsoft.Resources/tags/*",
    ]

    not_actions = [
      # Prevent privilege escalation
      "Microsoft.Authorization/roleAssignments/delete",
      "Microsoft.Authorization/roleDefinitions/write",
      "Microsoft.Authorization/roleDefinitions/delete",
    ]

    data_actions = [
      # Key Vault data plane (read/write secrets for database credentials)
      "Microsoft.KeyVault/vaults/secrets/*",

      # Storage data plane (blob read/write for images, models)
      "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/*",

      # Service Bus data plane (send/receive messages)
      "Microsoft.ServiceBus/namespaces/messages/*",
    ]
  }

  assignable_scopes = [
    data.azurerm_subscription.current.id,
  ]
}

# -----------------------------------------------------------------------------
# Service Principal: Identity that Ent Home authenticates as
#
# Option A (default): Federated Identity Credential (OIDC, no secret)
# Option B: Client secret (set create_client_secret = true)
# -----------------------------------------------------------------------------

resource "azuread_application" "ent" {
  display_name = var.service_principal_name
  owners       = [data.azuread_client_config.current.object_id]

  tags = values(var.tags)
}

resource "azuread_service_principal" "ent" {
  client_id = azuread_application.ent.client_id
  owners    = [data.azuread_client_config.current.object_id]
}

resource "azuread_application_federated_identity_credential" "ent" {
  application_id = azuread_application.ent.id
  display_name   = "ent-home-federated"
  description    = "Federated credential for Ent Home to authenticate via OIDC"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "repo:ent-security/ent-platform:environment:production"
}

# Bind the custom role to the service principal at subscription scope
resource "azurerm_role_assignment" "ent_deploy" {
  scope              = data.azurerm_subscription.current.id
  role_definition_id = azurerm_role_definition.ent_deploy.role_definition_resource_id
  principal_id       = azuread_service_principal.ent.object_id
}
