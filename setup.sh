#!/usr/bin/env bash
#
# One-time manual setup for the Ent Security deployment identity in a customer
# Azure subscription, using only the Azure CLI (`az`) — no OpenTofu/Terraform.
#
# Idempotent: safe to re-run. Each step checks for the existing object before
# creating it, so a second run reconciles rather than erroring.
#
# Creates:
#   1. Resource provider registrations
#   2. Custom role definition ("Ent Platform Deploy Role")
#   3. App registration + service principal ("ent-platform-deploy")
#   4. Two federated identity credentials — NO client secret is ever created:
#        - GitHub Actions OIDC (ent-platform deploy workflow)
#        - EKS workload identity (Ent Home deploy job, home-prod cluster)
#   5. Role assignment binding the role to the SP, gated by an ABAC condition
#      that blocks granting/removing Owner, User Access Administrator, and
#      Role Based Access Control Administrator (privilege-escalation guard).
#   6. OpenSearch app registration + service principal (os_admin / os_reader)
#
# Prerequisites:
#   - az >= 2.37 (for `az ad app federated-credential`), logged in (`az login`)
#   - Rights to create custom role definitions in the subscription AND to create
#     Entra app registrations in the tenant (e.g. Owner + Application Administrator)
#
# Usage:
#   ./setup.sh --subscription <subscription-id> [overrides]
#
# When finished, paste the printed `application_client_id` and `tenant_id` into
# the Azure connection panel in Ent onboarding.

set -euo pipefail

# ── Frozen, fleet-wide contracts pinned by Ent (override only if you know why) ─
ROLE_NAME="Ent Platform Deploy Role"
ROLE_DESCRIPTION="Custom role that grants Ent permissions to deploy and manage infrastructure in this subscription"
SP_NAME="ent-platform-deploy"
GITHUB_REPOSITORY="ent-security/ent-platform"
GITHUB_REF="refs/heads/main"
EKS_OIDC_ISSUER="https://oidc.eks.us-west-1.amazonaws.com/id/98DF15409F88BD228838D6794CA04EAD"
DEPLOY_SA_SUBJECT="system:serviceaccount:ent-home:ent-home-api"

SUBSCRIPTION_ID=""

# Built-in roles the deploy SP must NOT be able to assign or remove (escalation paths).
readonly FORBIDDEN_ROLE_GUIDS="8e3af657-a8ff-443c-a75c-2fe8c4bcb635, 18d7d88d-d35e-4fb5-a5c3-7773c20a72d9, f58310d9-a9f6-439a-9e8d-f62e7b41a168"

usage() {
  cat <<'USAGE'
One-time manual setup for the Ent Security deployment identity (Azure CLI only).

Usage:
  ./setup.sh --subscription <subscription-id> [overrides]

Required:
  -s, --subscription <id>     Target Azure subscription ID.

Overrides (frozen contracts — change only if you know why):
  --role-name <name>          Custom role display name.
  --sp-name <name>            App registration / service principal display name.
  --github-repository <o/r>   GitHub repo for the Actions OIDC federated credential.
  --github-ref <ref>          Git ref for the Actions federated credential.
  --eks-oidc-issuer <url>     EKS OIDC issuer URL for the workload-identity credential.
  --deploy-sa-subject <sub>   Kubernetes service-account subject for the EKS credential.
  -h, --help                  Show this help.

On success, paste the printed application_client_id and tenant_id into Ent onboarding.
USAGE
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--subscription)         SUBSCRIPTION_ID="$2"; shift 2 ;;
    --role-name)               ROLE_NAME="$2"; shift 2 ;;
    --sp-name)                 SP_NAME="$2"; shift 2 ;;
    --github-repository)       GITHUB_REPOSITORY="$2"; shift 2 ;;
    --github-ref)              GITHUB_REF="$2"; shift 2 ;;
    --eks-oidc-issuer)         EKS_OIDC_ISSUER="$2"; shift 2 ;;
    --deploy-sa-subject)       DEPLOY_SA_SUBJECT="$2"; shift 2 ;;
    -h|--help)                 usage 0 ;;
    *) echo "Unknown argument: $1" >&2; usage 1 ;;
  esac
done

if [[ -z "$SUBSCRIPTION_ID" ]]; then
  echo "ERROR: --subscription <subscription-id> is required." >&2
  usage 1
fi

if ! command -v az >/dev/null 2>&1; then
  echo "ERROR: the Azure CLI (az) is not on PATH. Install it and run 'az login'." >&2
  exit 1
fi

AZ=(az --only-show-errors)
SCOPE="/subscriptions/${SUBSCRIPTION_ID}"

"${AZ[@]}" account set --subscription "$SUBSCRIPTION_ID"
TENANT_ID="$("${AZ[@]}" account show --query tenantId -o tsv)"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

log() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

# ── 1. Resource provider registration ────────────────────────────────────────
log "Registering resource providers"
for ns in \
  Microsoft.ContainerService Microsoft.DBforPostgreSQL Microsoft.Cache \
  Microsoft.ContainerRegistry Microsoft.ServiceBus Microsoft.Storage \
  Microsoft.KeyVault Microsoft.Network Microsoft.ManagedIdentity \
  Microsoft.Compute Microsoft.Resources; do
  echo "  - $ns"
  "${AZ[@]}" provider register --namespace "$ns" --subscription "$SUBSCRIPTION_ID" >/dev/null
done

# ── 2. Custom role definition ─────────────────────────────────────────────────
log "Creating/updating custom role definition: $ROLE_NAME"
cat >"$WORKDIR/role.json" <<JSON
{
  "Name": "${ROLE_NAME}",
  "Description": "${ROLE_DESCRIPTION}",
  "Actions": [
    "Microsoft.Resources/subscriptions/resourceGroups/read",
    "Microsoft.Resources/subscriptions/resourceGroups/write",
    "Microsoft.Resources/subscriptions/resourceGroups/delete",
    "Microsoft.Resources/deployments/*",
    "Microsoft.Network/virtualNetworks/*",
    "Microsoft.Network/networkSecurityGroups/*",
    "Microsoft.Network/natGateways/*",
    "Microsoft.Network/publicIPAddresses/*",
    "Microsoft.Network/privateEndpoints/*",
    "Microsoft.Network/privateDnsZones/*",
    "Microsoft.Network/applicationGateways/*",
    "Microsoft.ContainerService/managedClusters/*",
    "Microsoft.ContainerService/locations/*",
    "Microsoft.ContainerRegistry/registries/*",
    "Microsoft.ContainerRegistry/locations/*",
    "Microsoft.DBforPostgreSQL/flexibleServers/*",
    "Microsoft.DBforPostgreSQL/locations/*",
    "Microsoft.Cache/redis/*",
    "Microsoft.Cache/locations/*",
    "Microsoft.KeyVault/vaults/*",
    "Microsoft.KeyVault/locations/*",
    "Microsoft.Storage/storageAccounts/*",
    "Microsoft.Storage/locations/*",
    "Microsoft.ServiceBus/namespaces/*",
    "Microsoft.ServiceBus/locations/*",
    "Microsoft.Network/dnszones/*",
    "Microsoft.ManagedIdentity/userAssignedIdentities/*",
    "Microsoft.Authorization/roleAssignments/*",
    "Microsoft.Authorization/roleDefinitions/read",
    "Microsoft.Resources/subscriptions/providers/read",
    "Microsoft.Compute/skus/read",
    "Microsoft.CognitiveServices/accounts/*",
    "Microsoft.CognitiveServices/locations/*",
    "Microsoft.CognitiveServices/deployments/*",
    "Microsoft.Insights/*/read",
    "Microsoft.OperationalInsights/*/read",
    "Microsoft.Resources/tags/*"
  ],
  "NotActions": [
    "Microsoft.Authorization/roleDefinitions/write",
    "Microsoft.Authorization/roleDefinitions/delete"
  ],
  "DataActions": [
    "Microsoft.KeyVault/vaults/secrets/*",
    "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/*",
    "Microsoft.ServiceBus/namespaces/messages/*",
    "Microsoft.CognitiveServices/accounts/OpenAI/*",
    "Microsoft.CognitiveServices/accounts/deployments/*"
  ],
  "NotDataActions": [],
  "AssignableScopes": ["${SCOPE}"]
}
JSON

if [[ -n "$("${AZ[@]}" role definition list --name "$ROLE_NAME" --scope "$SCOPE" --query "[0].name" -o tsv)" ]]; then
  "${AZ[@]}" role definition update --role-definition "@$WORKDIR/role.json" >/dev/null
  echo "  updated existing role definition"
else
  "${AZ[@]}" role definition create --role-definition "@$WORKDIR/role.json" >/dev/null
  echo "  created role definition"
fi

# ── 3. App registration + service principal ───────────────────────────────────
log "Ensuring app registration + service principal: $SP_NAME"
ENT_APP_ID="$("${AZ[@]}" ad app list --display-name "$SP_NAME" --query "[0].appId" -o tsv)"
if [[ -z "$ENT_APP_ID" ]]; then
  ENT_APP_ID="$("${AZ[@]}" ad app create --display-name "$SP_NAME" --sign-in-audience AzureADMyOrg --query appId -o tsv)"
  echo "  created app registration ($ENT_APP_ID)"
else
  echo "  reusing app registration ($ENT_APP_ID)"
fi
ENT_APP_OBJECT_ID="$("${AZ[@]}" ad app show --id "$ENT_APP_ID" --query id -o tsv)"

if ! "${AZ[@]}" ad sp show --id "$ENT_APP_ID" >/dev/null 2>&1; then
  "${AZ[@]}" ad sp create --id "$ENT_APP_ID" >/dev/null
  echo "  created service principal"
else
  echo "  reusing service principal"
fi
ENT_SP_OBJECT_ID="$("${AZ[@]}" ad sp show --id "$ENT_APP_ID" --query id -o tsv)"

# ── 4. Federated identity credentials (keyless) ───────────────────────────────
ensure_fic() {
  # $1 name, $2 issuer, $3 subject
  if [[ -n "$("${AZ[@]}" ad app federated-credential list --id "$ENT_APP_OBJECT_ID" --query "[?name=='$1'].name | [0]" -o tsv)" ]]; then
    echo "  fic '$1' already present"
    return
  fi
  cat >"$WORKDIR/fic.json" <<JSON
{
  "name": "$1",
  "issuer": "$2",
  "subject": "$3",
  "audiences": ["api://AzureADTokenExchange"]
}
JSON
  "${AZ[@]}" ad app federated-credential create --id "$ENT_APP_OBJECT_ID" --parameters "@$WORKDIR/fic.json" >/dev/null
  echo "  created fic '$1'"
}

log "Configuring federated credentials (no client secret)"
ensure_fic "ent-home-federated" "https://token.actions.githubusercontent.com" "repo:${GITHUB_REPOSITORY}:ref:${GITHUB_REF}"
ensure_fic "ent-home-eks-federated" "$EKS_OIDC_ISSUER" "$DEPLOY_SA_SUBJECT"

# ── 5. Role assignment with ABAC privilege-escalation guard ───────────────────
log "Assigning role to the service principal (ABAC-gated)"
ABAC_CONDITION="$(cat <<COND
(
 (
  !(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})
 )
 OR
 (
  @Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAllValues:GuidNotEquals {${FORBIDDEN_ROLE_GUIDS}}
 )
)
AND
(
 (
  !(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})
 )
 OR
 (
  @Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAllValues:GuidNotEquals {${FORBIDDEN_ROLE_GUIDS}}
 )
)
COND
)"

if [[ -n "$("${AZ[@]}" role assignment list --assignee "$ENT_SP_OBJECT_ID" --role "$ROLE_NAME" --scope "$SCOPE" --query "[0].id" -o tsv 2>/dev/null)" ]]; then
  echo "  role assignment already present"
else
  # The role definition and the new SP can take a few seconds to propagate; retry.
  for attempt in 1 2 3 4 5; do
    if "${AZ[@]}" role assignment create \
        --assignee-object-id "$ENT_SP_OBJECT_ID" \
        --assignee-principal-type ServicePrincipal \
        --role "$ROLE_NAME" \
        --scope "$SCOPE" \
        --condition "$ABAC_CONDITION" \
        --condition-version "2.0" >/dev/null 2>&1; then
      echo "  created role assignment"
      break
    fi
    if [[ "$attempt" -eq 5 ]]; then
      echo "ERROR: role assignment failed after retries (role/SP propagation?). Re-run the script." >&2
      exit 1
    fi
    echo "  waiting for propagation (attempt $attempt)…"
    sleep 10
  done
fi

# ── 6. OpenSearch app registration + service principal ────────────────────────
log "Ensuring OpenSearch app registration: ${SP_NAME}-opensearch"
OS_APP_ID="$("${AZ[@]}" ad app list --display-name "${SP_NAME}-opensearch" --query "[0].appId" -o tsv)"
if [[ -z "$OS_APP_ID" ]]; then
  cat >"$WORKDIR/approles.json" <<JSON
[
  {
    "allowedMemberTypes": ["Application"],
    "description": "Full read/write access to OpenSearch indices and cluster operations",
    "displayName": "os_admin",
    "isEnabled": true,
    "id": "$(uuidgen | tr '[:upper:]' '[:lower:]')",
    "value": "os_admin"
  },
  {
    "allowedMemberTypes": ["Application"],
    "description": "Read-only access to OpenSearch indices for queries and dashboards",
    "displayName": "os_reader",
    "isEnabled": true,
    "id": "$(uuidgen | tr '[:upper:]' '[:lower:]')",
    "value": "os_reader"
  }
]
JSON
  OS_APP_ID="$("${AZ[@]}" ad app create \
    --display-name "${SP_NAME}-opensearch" \
    --sign-in-audience AzureADMyOrg \
    --identifier-uris "api://${TENANT_ID}/opensearch" \
    --app-roles "@$WORKDIR/approles.json" \
    --query appId -o tsv)"
  echo "  created OpenSearch app ($OS_APP_ID)"
else
  echo "  reusing OpenSearch app ($OS_APP_ID)"
fi

if ! "${AZ[@]}" ad sp show --id "$OS_APP_ID" >/dev/null 2>&1; then
  "${AZ[@]}" ad sp create --id "$OS_APP_ID" >/dev/null
  echo "  created OpenSearch service principal"
else
  echo "  reusing OpenSearch service principal"
fi
OS_SP_OBJECT_ID="$("${AZ[@]}" ad sp show --id "$OS_APP_ID" --query id -o tsv)"

# ── Outputs ───────────────────────────────────────────────────────────────────
ROLE_DEF_ID="$("${AZ[@]}" role definition list --name "$ROLE_NAME" --scope "$SCOPE" --query "[0].id" -o tsv)"

cat <<OUT

$(printf '\033[1m✓ Setup complete.\033[0m')

Paste these two values into the Azure connection panel in Ent onboarding:

  application_client_id : ${ENT_APP_ID}
  tenant_id             : ${TENANT_ID}

Other outputs (for reference):

  subscription_id                        : ${SUBSCRIPTION_ID}
  service_principal_object_id            : ${ENT_SP_OBJECT_ID}
  role_definition_name                   : ${ROLE_NAME}
  role_definition_id                     : ${ROLE_DEF_ID}
  opensearch_client_id                   : ${OS_APP_ID}
  opensearch_identifier_uri              : api://${TENANT_ID}/opensearch
  opensearch_service_principal_object_id : ${OS_SP_OBJECT_ID}
OUT
