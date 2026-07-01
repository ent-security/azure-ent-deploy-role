#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
  One-time manual setup for the Ent Security deployment identity in a customer
  Azure subscription, using only the Azure CLI (az) — no OpenTofu/Terraform.
  PowerShell equivalent of setup.sh.

.DESCRIPTION
  Idempotent: safe to re-run. Each step checks for the existing object before
  creating it, so a second run reconciles rather than erroring.

  Creates:
    1. Resource provider registrations
    2. Custom role definition ("Ent Platform Deploy Role")
    3. App registration + service principal ("ent-platform-deploy")
    4. Two federated identity credentials — NO client secret is ever created:
         - GitHub Actions OIDC (ent-platform deploy workflow)
         - EKS workload identity (Ent Home deploy job; home-prod by default,
           -Env dev for Ent-internal testing only)
    5. Role assignment binding the role to the SP, gated by an ABAC condition
       that blocks granting/removing Owner, User Access Administrator, and
       Role Based Access Control Administrator (privilege-escalation guard).
    6. OpenSearch app registration + service principal (os_admin / os_reader)

  Prerequisites:
    - PowerShell 7+
    - Azure CLI (az) >= 2.37, logged in (az login)
    - Rights to create custom role definitions in the subscription AND Entra app
      registrations in the tenant (e.g. Owner + Application Administrator)

.EXAMPLE
  ./setup.ps1 -Subscription 00000000-0000-0000-0000-000000000000

.EXAMPLE
  # Ent-internal dev testing (separate ent-platform-deploy-dev identity):
  ./setup.ps1 -Subscription <dev-sub-id> -Env dev
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory, HelpMessage = 'Target Azure subscription ID')]
    [string] $Subscription,

    [string] $RoleName = 'Ent Platform Deploy Role',
    [string] $RoleDescription = 'Custom role that grants Ent permissions to deploy and manage infrastructure in this subscription',
    [string] $SpName = '',            # default: ent-platform-deploy (suffixed -dev for -Env dev)
    [string] $GithubRepository = 'ent-security/ent-platform',
    [string] $GithubRef = 'refs/heads/main',
    [string] $Env = '',               # prod|dev (defaults to prod); not combinable with -EksOidcIssuer
    [string] $EksOidcIssuer = '',     # explicit issuer override (advanced)
    [string] $DeploySaSubject = 'system:serviceaccount:ent-home:ent-home-api'
)

$ErrorActionPreference = 'Stop'
# az calls are checked explicitly via $LASTEXITCODE; never let a native command
# auto-throw, so the "expected failure" existence checks below behave predictably.
$PSNativeCommandUseErrorActionPreference = $false

# Known Ent home-cluster EKS OIDC issuers. Customer tenants ALWAYS trust prod;
# dev is for Ent-internal testing only and must never be used for a customer.
$ProdEksOidcIssuer = 'https://oidc.eks.us-west-1.amazonaws.com/id/98DF15409F88BD228838D6794CA04EAD'
$DevEksOidcIssuer  = 'https://oidc.eks.us-west-1.amazonaws.com/id/B86CB0977AB2E6A4A50182E607F3B4D7'

# Built-in roles the deploy SP must NOT be able to assign or remove (escalation paths).
$ForbiddenRoleGuids = '8e3af657-a8ff-443c-a75c-2fe8c4bcb635, 18d7d88d-d35e-4fb5-a5c3-7773c20a72d9, f58310d9-a9f6-439a-9e8d-f62e7b41a168'

function Write-Step { param([string] $Message) Write-Host "`n==> $Message" -ForegroundColor Cyan }

# Run az with the given args; throw on non-zero exit. Returns trimmed stdout.
function Invoke-Az {
    $output = & az @args
    if ($LASTEXITCODE -ne 0) { throw "az $($args -join ' ') failed (exit $LASTEXITCODE)" }
    if ($null -eq $output) { return '' }
    return (($output -join "`n").Trim())
}

# Resolve the EKS OIDC issuer: an explicit -EksOidcIssuer wins; otherwise pick by
# -Env. The two are mutually exclusive to avoid ambiguity.
if ($EksOidcIssuer -and $Env) {
    throw 'Pass either -Env or -EksOidcIssuer, not both.'
}
if (-not $EksOidcIssuer) {
    $envResolved = if ($Env) { $Env } else { 'prod' }
    switch ($envResolved) {
        'prod' { $EksOidcIssuer = $ProdEksOidcIssuer }
        'dev'  { $EksOidcIssuer = $DevEksOidcIssuer }
        default { throw "-Env must be 'prod' or 'dev' (got '$Env')." }
    }
}
if ($EksOidcIssuer -cnotmatch '^https://oidc\.eks\.[a-z0-9-]+\.amazonaws\.com/id/[A-F0-9]+$') {
    throw "EKS issuer must look like https://oidc.eks.<region>.amazonaws.com/id/<OIDC_ID>; got: $EksOidcIssuer"
}
$IsDev = ($EksOidcIssuer -eq $DevEksOidcIssuer)
if ($IsDev) {
    Write-Warning 'Trusting the Ent home-DEV EKS cluster — Ent-internal testing only; never a customer tenant.'
}

# Default the app/SP name. Dev gets a fully separate '-dev' identity (its own app
# registration, service principal, federated credentials, and OpenSearch app) so
# it never collides with the home/prod app. An explicit -SpName overrides this.
if (-not $SpName) {
    $SpName = 'ent-platform-deploy'
    if ($IsDev) { $SpName = "$SpName-dev" }
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'The Azure CLI (az) is not on PATH. Install it and run "az login".'
}

# Quiet az's warning-level chatter via the config env var rather than the
# --only-show-errors global flag (recent az rejects that flag before the command
# group: `az --only-show-errors account set` -> "'set' is misspelled").
$env:AZURE_CORE_ONLY_SHOW_ERRORS = 'true'
$Scope = "/subscriptions/$Subscription"

Invoke-Az account set --subscription $Subscription | Out-Null
$TenantId = Invoke-Az account show --query tenantId -o tsv

$workdir = Join-Path ([System.IO.Path]::GetTempPath()) ("ent-setup-" + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $workdir | Out-Null
try {
    # ── 1. Resource provider registration ──────────────────────────────────────
    Write-Step 'Registering resource providers'
    $providers = @(
        'Microsoft.ContainerService', 'Microsoft.DBforPostgreSQL', 'Microsoft.Cache',
        'Microsoft.ContainerRegistry', 'Microsoft.ServiceBus', 'Microsoft.Storage',
        'Microsoft.KeyVault', 'Microsoft.Network', 'Microsoft.ManagedIdentity',
        'Microsoft.Compute', 'Microsoft.CognitiveServices', 'Microsoft.Resources'
    )
    foreach ($ns in $providers) {
        Write-Host "  - $ns"
        Invoke-Az provider register --namespace $ns --subscription $Subscription | Out-Null
    }

    # ── 2. Custom role definition ───────────────────────────────────────────────
    Write-Step "Ensuring custom role definition: $RoleName"
    $roleJson = @"
{
  "Name": "$RoleName",
  "Description": "$RoleDescription",
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
    "Microsoft.Compute/locations/usages/read",
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
    "Microsoft.KeyVault/vaults/certificates/*",
    "Microsoft.KeyVault/vaults/keys/*",
    "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/*",
    "Microsoft.ServiceBus/namespaces/messages/*",
    "Microsoft.CognitiveServices/accounts/OpenAI/*",
    "Microsoft.CognitiveServices/accounts/deployments/*"
  ],
  "NotDataActions": [],
  "AssignableScopes": ["$Scope"]
}
"@
    $rolePath = Join-Path $workdir 'role.json'
    [System.IO.File]::WriteAllText($rolePath, $roleJson)

    if (Invoke-Az role definition list --name $RoleName --scope $Scope --query "[0].name" -o tsv) {
        # Reconcile the existing role so a re-run picks up permission changes (new Actions) — otherwise a
        # permission added to an already-onboarded subscription's role would never land. The role is
        # scoped to this one subscription, so the update needs write only here. If it was manually
        # broadened to other subscriptions you can't write to, the update can fail with
        # LinkedAuthorizationFailed — warn and continue rather than abort; pass -RoleName to manage a
        # separate single-subscription role instead.
        try {
            Invoke-Az role definition update --role-definition "@$rolePath" | Out-Null
            Write-Host "  updated existing role definition '$RoleName'"
        }
        catch {
            Write-Host "  WARNING: could not update '$RoleName' (a multi-subscription role you lack write on?); left as-is. Re-run with -RoleName <name> to manage a single-subscription role here."
        }
    }
    else {
        Invoke-Az role definition create --role-definition "@$rolePath" | Out-Null
        Write-Host '  created role definition'
    }

    # ── 3. App registration + service principal ─────────────────────────────────
    Write-Step "Ensuring app registration + service principal: $SpName"
    $entAppId = Invoke-Az ad app list --display-name $SpName --query "[0].appId" -o tsv
    if (-not $entAppId) {
        $entAppId = Invoke-Az ad app create --display-name $SpName --sign-in-audience AzureADMyOrg --query appId -o tsv
        Write-Host "  created app registration ($entAppId)"
    }
    else {
        Write-Host "  reusing app registration ($entAppId)"
    }
    $entAppObjectId = Invoke-Az ad app show --id $entAppId --query id -o tsv

    & az ad sp show --id $entAppId 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Invoke-Az ad sp create --id $entAppId | Out-Null
        Write-Host '  created service principal'
    }
    else {
        Write-Host '  reusing service principal'
    }
    $entSpObjectId = Invoke-Az ad sp show --id $entAppId --query id -o tsv

    # ── 4. Federated identity credentials (keyless) ─────────────────────────────
    function EnsureFic {
        param([string] $Name, [string] $Issuer, [string] $Subject)
        # Azure enforces uniqueness on issuer+subject (not name), so match that
        # combo — an equivalent credential may already exist under a different name.
        $existing = Invoke-Az ad app federated-credential list --id $entAppObjectId `
            --query "[?issuer=='$Issuer' && subject=='$Subject'].name | [0]" -o tsv
        if ($existing) {
            Write-Host "  fic for this issuer+subject already present (name: $existing) — skipping '$Name'"
            return
        }
        $ficJson = @"
{
  "name": "$Name",
  "issuer": "$Issuer",
  "subject": "$Subject",
  "audiences": ["api://AzureADTokenExchange"]
}
"@
        $ficPath = Join-Path $workdir 'fic.json'
        [System.IO.File]::WriteAllText($ficPath, $ficJson)
        Invoke-Az ad app federated-credential create --id $entAppObjectId --parameters "@$ficPath" | Out-Null
        Write-Host "  created fic '$Name'"
    }

    Write-Step "Configuring federated credentials (no client secret) — EKS issuer: $EksOidcIssuer"
    EnsureFic -Name 'ent-home-federated' -Issuer 'https://token.actions.githubusercontent.com' -Subject "repo:${GithubRepository}:ref:${GithubRef}"
    EnsureFic -Name 'ent-home-eks-federated' -Issuer $EksOidcIssuer -Subject $DeploySaSubject

    # ── 5. Role assignment with ABAC privilege-escalation guard ─────────────────
    Write-Step 'Assigning role to the service principal (ABAC-gated)'
    $abacTemplate = @'
( ( !(ActionMatches{'Microsoft.Authorization/roleAssignments/write'}) ) OR ( @Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAllValues:GuidNotEquals {__GUIDS__} ) ) AND ( ( !(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'}) ) OR ( @Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAllValues:GuidNotEquals {__GUIDS__} ) )
'@
    $abac = $abacTemplate.Replace('__GUIDS__', $ForbiddenRoleGuids)

    $existingAssignment = & az role assignment list --assignee $entSpObjectId --role $RoleName --scope $Scope --query "[0].id" -o tsv 2>$null
    if ($existingAssignment) {
        Write-Host '  role assignment already present'
    }
    else {
        # The role definition and the new SP can take a few seconds to propagate; retry.
        for ($attempt = 1; $attempt -le 5; $attempt++) {
            & az role assignment create `
                --assignee-object-id $entSpObjectId `
                --assignee-principal-type ServicePrincipal `
                --role $RoleName `
                --scope $Scope `
                --condition $abac `
                --condition-version '2.0' 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) { Write-Host '  created role assignment'; break }
            if ($attempt -eq 5) { throw 'Role assignment failed after retries (role/SP propagation?). Re-run the script.' }
            Write-Host "  waiting for propagation (attempt $attempt)…"
            Start-Sleep -Seconds 10
        }
    }

    # ── 6. OpenSearch app registration + service principal ──────────────────────
    Write-Step "Ensuring OpenSearch app registration: $SpName-opensearch"
    # Dev gets its own identifier URI so its OpenSearch app stays isolated from home's.
    $osUri = "api://$TenantId/opensearch"
    if ($IsDev) { $osUri = "$osUri-dev" }
    $osAppId = Invoke-Az ad app list --display-name "$SpName-opensearch" --query "[0].appId" -o tsv
    if (-not $osAppId) {
        # Fall back to the identifier URI (uniqueness-constrained): an equivalent
        # OpenSearch app may already exist under a different display name.
        $osAppId = Invoke-Az ad app list --identifier-uri $osUri --query "[0].appId" -o tsv
    }
    if (-not $osAppId) {
        $appRolesJson = @"
[
  {
    "allowedMemberTypes": ["Application"],
    "description": "Full read/write access to OpenSearch indices and cluster operations",
    "displayName": "os_admin",
    "isEnabled": true,
    "id": "$([guid]::NewGuid().ToString())",
    "value": "os_admin"
  },
  {
    "allowedMemberTypes": ["Application"],
    "description": "Read-only access to OpenSearch indices for queries and dashboards",
    "displayName": "os_reader",
    "isEnabled": true,
    "id": "$([guid]::NewGuid().ToString())",
    "value": "os_reader"
  }
]
"@
        $rolesPath = Join-Path $workdir 'approles.json'
        [System.IO.File]::WriteAllText($rolesPath, $appRolesJson)
        $osAppId = Invoke-Az ad app create --display-name "$SpName-opensearch" `
            --sign-in-audience AzureADMyOrg --identifier-uris $osUri `
            --app-roles "@$rolesPath" --query appId -o tsv
        Write-Host "  created OpenSearch app ($osAppId)"
    }
    else {
        Write-Host "  reusing OpenSearch app ($osAppId)"
    }

    & az ad sp show --id $osAppId 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Invoke-Az ad sp create --id $osAppId | Out-Null
        Write-Host '  created OpenSearch service principal'
    }
    else {
        Write-Host '  reusing OpenSearch service principal'
    }
    $osSpObjectId = Invoke-Az ad sp show --id $osAppId --query id -o tsv

    # ── Outputs ─────────────────────────────────────────────────────────────────
    $roleDefId = Invoke-Az role definition list --name $RoleName --scope $Scope --query "[0].id" -o tsv

    Write-Host ''
    Write-Host '✓ Setup complete.' -ForegroundColor Green
    Write-Host ''
    Write-Host 'Paste these two values into the Azure connection panel in Ent onboarding:'
    Write-Host ''
    Write-Host "  application_client_id : $entAppId"
    Write-Host "  tenant_id             : $TenantId"
    Write-Host ''
    Write-Host 'Other outputs (for reference):'
    Write-Host ''
    Write-Host "  subscription_id                        : $Subscription"
    Write-Host "  service_principal_object_id            : $entSpObjectId"
    Write-Host "  role_definition_name                   : $RoleName"
    Write-Host "  role_definition_id                     : $roleDefId"
    Write-Host "  opensearch_client_id                   : $osAppId"
    Write-Host "  opensearch_identifier_uri              : $osUri"
    Write-Host "  opensearch_service_principal_object_id : $osSpObjectId"
}
finally {
    Remove-Item -Recurse -Force -Path $workdir -ErrorAction SilentlyContinue
}
