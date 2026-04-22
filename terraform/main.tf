data "azurerm_subscription" "current" {}
data "azuread_client_config" "current" {}

# =============================================================================
# AUDIT SUMMARY (2026-04-12)
#
# Compared against resources in ent-platform/deploy/tofu/azure/platform/.
#
# Findings addressed in this revision:
#
#   1. Microsoft.Cache/* was a full wildcard. Platform only creates
#      azurerm_redis_cache (classic Redis, not Managed Redis). Scoped to
#      Microsoft.Cache/redis/* and Microsoft.Cache/locations/*.
#
#   2. Microsoft.Compute/locations/* was overly broad. Only
#      Microsoft.Compute/skus/read is used (SKU availability checks during
#      AKS provisioning). Removed the locations wildcard.
#
#   3. Microsoft.Insights/* and Microsoft.OperationalInsights/* were full
#      wildcards. The platform module creates no monitoring resources directly.
#      Scoped to read-only (AKS diagnostic settings are managed by AKS's own
#      identity, not the deploy SP).
#
#   4. Federated identity credential subject used "environment:production"
#      but the azure-deploy.yml workflow does NOT declare a GitHub Actions
#      environment. Changed to configurable var with ref-based default.
#
#   5. roleAssignments/delete is now granted (not blocked via not_actions).
#      OpenTofu requires delete to replace role assignments when their parent
#      resource changes — e.g., swapping AI models, renaming resources,
#      rotating managed identities. Privilege-escalation risk (self-unbind,
#      reassign Owner) is mitigated by an ABAC condition on the role
#      assignment below that excludes Owner, User Access Administrator, and
#      Role Based Access Control Administrator from the roles the SP can
#      assign or delete.
#
# Remaining accepted risks:
#   - Microsoft.ContainerService/managedClusters/* grants full AKS control
#     (needed for create/update/delete of cluster + node pools + addons).
#   - Microsoft.Authorization/roleAssignments/write can assign any built-in
#     role *except* the three gated by the ABAC condition. Acceptable in a
#     single-tenant subscription; Azure PIM is the mitigation for shared subs.
# =============================================================================

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

      # ── Networking (VNet, Subnets, NSG, NAT Gateway, Public IP, AppGW) ─
      "Microsoft.Network/virtualNetworks/*",
      "Microsoft.Network/networkSecurityGroups/*",
      "Microsoft.Network/natGateways/*",
      "Microsoft.Network/publicIPAddresses/*",
      "Microsoft.Network/privateEndpoints/*",
      "Microsoft.Network/privateDnsZones/*",
      "Microsoft.Network/applicationGateways/*",

      # ── AKS ───────────────────────────────────────────────────────────
      "Microsoft.ContainerService/managedClusters/*",
      "Microsoft.ContainerService/locations/*",

      # ── Container Registry ────────────────────────────────────────────
      "Microsoft.ContainerRegistry/registries/*",
      "Microsoft.ContainerRegistry/locations/*",

      # ── PostgreSQL Flexible Server ────────────────────────────────────
      "Microsoft.DBforPostgreSQL/flexibleServers/*",
      "Microsoft.DBforPostgreSQL/locations/*",

      # ── Redis (Azure Cache for Redis — classic SKU only) ──────────────
      # Platform uses azurerm_redis_cache (Standard tier), not Managed Redis.
      "Microsoft.Cache/redis/*",
      "Microsoft.Cache/locations/*",

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
      # roleAssignments/* grants write+read+delete, which tofu needs to
      # replace assignments when parent resources change (model swaps,
      # MI rotations, etc.). The ABAC condition on the role assignment
      # below blocks the SP from granting or removing Owner / User Access
      # Administrator / RBAC Administrator, which are the escalation paths.
      "Microsoft.ManagedIdentity/userAssignedIdentities/*",
      "Microsoft.Authorization/roleAssignments/*",
      "Microsoft.Authorization/roleDefinitions/read",

      # ── Provider Registration (for validation checks) ─────────────────
      "Microsoft.Resources/subscriptions/providers/read",

      # ── Compute (SKU availability checks for AKS VM sizing) ───────────
      "Microsoft.Compute/skus/read",

      # ── AI Services (Azure OpenAI, Cognitive Services) ────────────────
      "Microsoft.CognitiveServices/accounts/*",
      "Microsoft.CognitiveServices/locations/*",
      "Microsoft.CognitiveServices/deployments/*",

      # ── Monitoring (read-only — AKS manages its own diagnostics) ──────
      "Microsoft.Insights/*/read",
      "Microsoft.OperationalInsights/*/read",

      # ── Tagging ───────────────────────────────────────────────────────
      "Microsoft.Resources/tags/*",
    ]

    not_actions = [
      # Block modifying role definitions themselves. Role-assignment write+delete
      # are permitted (see roleAssignments/* in actions above) but gated by the
      # ABAC condition on the role assignment below, which prevents the SP from
      # granting or removing the three escalation-enabling built-in roles.
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

      # AI Services data plane (inference API calls)
      "Microsoft.CognitiveServices/accounts/OpenAI/*",
      "Microsoft.CognitiveServices/accounts/deployments/*",
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
  description    = "Federated credential for Ent to authenticate via GitHub Actions OIDC"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "repo:${var.github_repository}:ref:${var.github_ref}"
}

# Bind the custom role to the service principal at subscription scope.
#
# ABAC condition blocks privilege escalation: the SP can write and delete role
# assignments (needed for tofu to replace them when parent resources change)
# but NOT for Owner, User Access Administrator, or Role Based Access Control
# Administrator. The two expressions cover write (Request side) and delete
# (Resource side) per the Microsoft Learn pattern:
# https://learn.microsoft.com/azure/role-based-access-control/delegate-role-assignments-examples
locals {
  # Built-in roles the SP must NOT be able to assign or remove.
  forbidden_role_guids = [
    "8e3af657-a8ff-443c-a75c-2fe8c4bcb635", # Owner
    "18d7d88d-d35e-4fb5-a5c3-7773c20a72d9", # User Access Administrator
    "f58310d9-a9f6-439a-9e8d-f62e7b41a168", # Role Based Access Control Administrator
  ]
}

resource "azurerm_role_assignment" "ent_deploy" {
  scope              = data.azurerm_subscription.current.id
  role_definition_id = azurerm_role_definition.ent_deploy.role_definition_resource_id
  principal_id       = azuread_service_principal.ent.object_id

  condition_version = "2.0"
  condition = <<-EOT
    (
     (
      !(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})
     )
     OR
     (
      @Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAllValues:GuidNotEquals {${join(", ", local.forbidden_role_guids)}}
     )
    )
    AND
    (
     (
      !(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})
     )
     OR
     (
      @Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAllValues:GuidNotEquals {${join(", ", local.forbidden_role_guids)}}
     )
    )
  EOT
}

# -----------------------------------------------------------------------------
# OpenSearch App Registration
#
# Azure AD application for OpenSearch authentication. Provides two app roles:
#   - os_admin: Full CRUD access (for event-indexer, admin-api)
#   - os_reader: Read-only access (for operator portal queries)
#
# The role assignment binding (MI → app role) happens in the platform Tofu
# module where the workload identity is created — NOT here.
# -----------------------------------------------------------------------------

resource "random_uuid" "opensearch_app_role_admin" {}
resource "random_uuid" "opensearch_app_role_reader" {}

resource "azuread_application" "opensearch" {
  display_name = "${var.service_principal_name}-opensearch"
  owners       = [data.azuread_client_config.current.object_id]

  # Azure AD requires tenant-verified domain or tenant ID in identifier URIs.
  # Use api://{tenant_id}/opensearch format to comply with default tenant policy.
  identifier_uris = ["api://${data.azuread_client_config.current.tenant_id}/opensearch"]

  app_role {
    allowed_member_types = ["Application"]
    description          = "Full read/write access to OpenSearch indices and cluster operations"
    display_name         = "os_admin"
    enabled              = true
    id                   = random_uuid.opensearch_app_role_admin.result
    value                = "os_admin"
  }

  app_role {
    allowed_member_types = ["Application"]
    description          = "Read-only access to OpenSearch indices for queries and dashboards"
    display_name         = "os_reader"
    enabled              = true
    id                   = random_uuid.opensearch_app_role_reader.result
    value                = "os_reader"
  }

  tags = values(var.tags)
}

resource "azuread_service_principal" "opensearch" {
  client_id = azuread_application.opensearch.client_id
  owners    = [data.azuread_client_config.current.object_id]
}
