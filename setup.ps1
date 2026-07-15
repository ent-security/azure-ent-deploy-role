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

  Steps:
    1. Resource provider registrations
    2. Capacity & quota checks — regional + DSv3 system-node vCPU quota, T4/A10
       GPU quota (5 T4 or 3 A10 full cards), Foundry catalog + TPM (any one
       approved model per tier). Failures prompt before anything is created.
    3. Custom role definition ("Ent Platform Deploy Role")
    4. App registration + service principal ("ent-platform-deploy")
    5. A keyless federated identity credential trusting the Ent Home (EKS)
       deploy path — the only identity customers trust (-Env dev is
       Ent-internal only)
    6. Role assignment, ABAC-gated to block granting/removing Owner, User
       Access Administrator, and RBAC Administrator (escalation guard)
    7. OpenSearch app registration + service principal (os_admin / os_reader)

  Prerequisites:
    - PowerShell 7+
    - Azure CLI (az) >= 2.37, logged in (az login)
    - Rights to create custom role definitions in the subscription AND Entra app
      registrations in the tenant (e.g. Owner + Application Administrator)

.EXAMPLE
  ./setup.ps1
  # Walks you through the subscription (Enter accepts your active az login), the
  # tenant details (name, region, SSO domains, superusers), and a final confirm.

.EXAMPLE
  ./setup.ps1 -Subscription 00000000-0000-0000-0000-000000000000
  # Skips the subscription prompt; still asks the tenant details + confirm.

.EXAMPLE
  # Ent-internal dev testing (separate ent-platform-deploy-dev identity):
  ./setup.ps1 -Subscription <dev-sub-id> -Env dev
#>

[CmdletBinding()]
param(
    # Target Azure subscription ID. Prompted for when omitted (Enter accepts the
    # active az subscription); required as a parameter for non-interactive runs.
    [string] $Subscription = '',

    [string] $RoleName = 'Ent Platform Deploy Role',
    [string] $RoleDescription = 'Custom role that grants Ent permissions to deploy and manage infrastructure in this subscription',
    [string] $SpName = '',            # default: ent-platform-deploy (suffixed -dev for -Env dev)
    [string] $Env = '',               # prod|dev (defaults to prod); not combinable with -EksOidcIssuer
    [string] $EksOidcIssuer = '',     # explicit issuer override (advanced)
    [string] $DeploySaSubject = 'system:serviceaccount:ent-home:ent-home-api'
)

# ── Tenant details (prompted below; blank on non-interactive runs) ────────────
$TenantName = ''
$Region     = ''
$SsoDomains = ''
$Superusers = ''

$ErrorActionPreference = 'Stop'
# az calls are checked explicitly via $LASTEXITCODE; never let a native command
# auto-throw, so the "expected failure" existence checks below behave predictably.
$PSNativeCommandUseErrorActionPreference = $false

# Bold-green Ent rune + "ENT" banner.
$Logo = @'

  ██    ██     ███████╗ ███╗   ██╗ ████████╗
  ██  ██       ██╔════╝ ████╗  ██║ ╚══██╔══╝
  ████  ██     █████╗   ██╔██╗ ██║    ██║
  ██  ██       ██╔══╝   ██║╚██╗██║    ██║
  ████         ███████╗ ██║ ╚████║    ██║
  ██           ╚══════╝ ╚═╝  ╚═══╝    ╚═╝
'@
Write-Host $Logo -ForegroundColor Green
Write-Host '  Ent Security — Azure deployment identity setup'

# Known Ent home-cluster EKS OIDC issuers. Customer tenants ALWAYS trust prod;
# dev is for Ent-internal testing only and must never be used for a customer.
$ProdEksOidcIssuer = 'https://oidc.eks.us-west-1.amazonaws.com/id/98DF15409F88BD228838D6794CA04EAD'
$DevEksOidcIssuer  = 'https://oidc.eks.us-west-1.amazonaws.com/id/B86CB0977AB2E6A4A50182E607F3B4D7'

# ── Capacity-check contracts (mirror ent-home-api validation + AzureModelSpec) ─
# Models are pinned name@version; a stale pin FAILs listing the region's versions.
$MinVcpusAvailable    = 150             # regional vCPU floor for an Ent deployment
$AksSystemVmSku       = 'Standard_D8s_v3'    # static AKS system pool SKU — ent-platform deploy/tofu/azure/platform/variables.tf (aks_vm_size)
$AksSystemVmFamily    = 'standardDSv3Family' # quota family the system SKU draws from
$AksSystemVmVcpus     = 8               # vCPUs one Standard_D8s_v3 system node needs
$FoundrySku           = 'GlobalStandard' # serving-tier deployment SKU (its TPM quota pool is checked)
$FoundryTierTpmK      = 250             # K TPM needed per tier (AzureModelSpec DEFAULT_CAPACITY)
# Benchmark-approved serving models per tier, BEST FIRST ("model" or
# "model@version"; bare names accept any catalog version — gpt-5.2's pin is
# TBD). Any ONE model per tier needs catalog presence + TPM headroom; the best
# passing one is recommended in the final handoff block.
$FoundryNormalModels = @('gpt-5.1@2025-11-13', 'gpt-5.2', 'gpt-4.1@2025-04-14', 'gpt-5@2025-08-07', 'gpt-5-mini@2025-08-07')
$FoundryFastModels   = @('gpt-4.1-mini@2025-04-14', 'gpt-5-nano@2025-08-07')
$FoundryNormalPick   = ''  # best passing model per tier — filled by the checks
$FoundryFastPick     = ''

# Baseline GPU cards per silicon: T4 = 4 vLLM chat replicas + 1 TEI (the
# decode-bound T4 tier needs many shallow pods); A10 = 2 + 1 (E4B-bf16 batch-32
# profile — GpuProfile.A10_E4B_BF16 — matches 4 T4s). Sources: ent-platform
# production-stack-models values.yaml + tei-embeddings chart.
$GpuT4Cards  = 5
$GpuA10Cards = 3
# T4/A10 quota families; VcpusPerCard = cheapest FULL-card VM (fractional A10
# SKUs don't count).
$GpuFamilies = @(
    @{ Label = 'GPU (T4 v3)';  Family = 'standardNCASt4v3Family';   Cards = $GpuT4Cards;  VcpusPerCard = 4;  Skus = 'NC4as_T4_v3 (4 vCPU, 1 T4), NC8as_T4_v3 (8), NC16as_T4_v3 (16), NC64as_T4_v3 (64, 4 T4)' }
    @{ Label = 'GPU (A10 v5)'; Family = 'standardNVADSA10v5Family'; Cards = $GpuA10Cards; VcpusPerCard = 36; Skus = 'NV36ads_A10_v5 (36 vCPU, 1 A10; NV6/12/18ads are fractional cards), NV72ads_A10_v5 (72, 2 A10)' }
    @{ Label = 'GPU (A10 v4)'; Family = 'standardNCADSA10v4Family'; Cards = $GpuA10Cards; VcpusPerCard = 32; Skus = 'NC32ads_A10_v4 (32 vCPU, 1 A10; NC8/16ads are fractional cards)' }
)
$GpuPassedSkus = @()    # quota families that passed — filled by the checks
$VcpuRegionStatus = ''  # vCPU check summaries for the handoff block
$VcpuSystemStatus = ''

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

# An explicit -EksOidcIssuer wins; otherwise -Env picks. Mutually exclusive.
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

# Dev gets a fully separate '-dev' identity so it never collides with home/prod.
if (-not $SpName) {
    $SpName = 'ent-platform-deploy'
    if ($IsDev) { $SpName = "$SpName-dev" }
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'The Azure CLI (az) is not on PATH. Install it and run "az login".'
}

# Quiet az warnings via env var — recent az rejects --only-show-errors when it
# precedes the command group.
$env:AZURE_CORE_ONLY_SHOW_ERRORS = 'true'

# ── Setup walkthrough ─────────────────────────────────────────────────────────
# Interactive only: piped runs skip prompts (-Subscription required; tenant
# details stay blank).
if (-not [Console]::IsInputRedirected) {
    if (-not $Subscription) {
        Write-Step 'Deployment target'
        # Enter accepts the active az subscription.
        $curSubId = ((& az account show --query id -o tsv 2>$null) | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { $curSubId = '' }
        if ($curSubId) {
            $curSubName = ((& az account show --query name -o tsv 2>$null) | Out-String).Trim()
            if ($LASTEXITCODE -ne 0) { $curSubName = '' }
            $answer = Read-Host "  Azure subscription ID [$curSubId — $curSubName]"
            $Subscription = if ($answer) { $answer } else { $curSubId }
        }
        else {
            $Subscription = Read-Host '  Azure subscription ID'
        }
    }

    Write-Step 'Tenant details (your Ent contact needs these)'
    Write-Host "  Answer a few questions — press Enter to skip any you don't have yet."
    Write-Host ''
    $TenantName = Read-Host '  Tenant name (e.g. Acme Prod)'
    $Region     = Read-Host '  Azure region (e.g. eastus)'
    $SsoDomains = Read-Host '  SSO domains, comma-separated (e.g. acme.com,acme.io)'
    $Superusers = Read-Host '  Superuser emails, comma-separated (e.g. admin@acme.com)'
}

if (-not $Subscription) {
    throw 'An Azure subscription ID is required — pass -Subscription <id> on non-interactive runs.'
}

# Confirm before mutating anything (interactive only; an explicit -Subscription
# on a non-interactive run is the consent). Only y/Y proceeds — Enter aborts.
if (-not [Console]::IsInputRedirected) {
    $subLabel = $Subscription
    $subName = ((& az account show --subscription $Subscription --query name -o tsv 2>$null) | Out-String).Trim()
    if ($LASTEXITCODE -eq 0 -and $subName) { $subLabel = "$Subscription — $subName" }
    Write-Host ''
    $confirm = Read-Host "Proceed with setup in subscription $subLabel? [y/N]"
    if ($confirm -notmatch '^[Yy]$') {
        Write-Host 'Aborted — nothing was changed.'
        exit 1
    }
}

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

    # ── 2. Capacity & quota checks ───────────────────────────────────────────────
    # Verify the region can host an Ent deployment before creating any permission:
    # regional + DSv3 system-node vCPUs, T4/A10 GPU cards, Foundry catalog + TPM.
    # Mirrors ent-home-api's AzureDeploymentValidationService but FAILs (onboarding
    # gate) instead of warning; az read errors still degrade to WARN (fail-open).
    $script:QuotaFails = 0
    $script:QuotaWarns = 0
    function Write-CheckResult {
        # $Status PASS|WARN|FAIL|INFO; INFO never gates.
        param([string] $Status, [string] $Label, [string] $Message)
        $color = switch ($Status) { 'PASS' { 'Green' } 'WARN' { 'Yellow' } 'INFO' { 'Cyan' } default { 'Red' } }
        if ($Status -eq 'WARN') { $script:QuotaWarns++ }
        if ($Status -eq 'FAIL') { $script:QuotaFails++ }
        Write-Host ("  {0,-4}  {1,-14} {2}" -f $Status, $Label, $Message) -ForegroundColor $color
    }
    function Write-CheckSection {
        param([string] $Title)
        $t = " $Title "
        $width = 76
        $pad = [Math]::Max(0, [int][Math]::Floor(($width - $t.Length) / 2))
        $right = [Math]::Max(0, $width - $pad - $t.Length)
        Write-Host ''
        Write-Host ('  ' + ('=' * $pad) + $t + ('=' * $right))
    }
    function Test-TierModels {
        # One line per candidate; any ONE passing (catalog + TPM) covers the tier.
        param([string] $Tier, [string[]] $Candidates)
        $tierOk = $false
        $tierPick = ''
        $results = @()

        foreach ($spec in $Candidates) {
            $model = $spec.Split('@')[0]
            $version = if ($spec.Contains('@')) { $spec.Split('@', 2)[1] } else { '' }

            # Catalog: pinned versions must match exactly; bare names accept any.
            $versions = @($script:FoundryCatalog | Where-Object { $_.n -eq $model } | ForEach-Object { $_.v } | Sort-Object -Unique)
            $catOk = $false
            if ($versions.Count -eq 0) {
                $catStr = 'not in catalog'
            }
            elseif (-not $version -or $versions -contains $version) {
                $catOk = $true
                $catStr = "catalog: $($versions -join ', ')"
            }
            else {
                $catStr = "catalog: $($versions -join ', ') (no $version)"
            }

            $usage = $script:FoundryUsages | Where-Object { $_.name.value -eq "OpenAI.$FoundrySku.$model" } | Select-Object -First 1
            $tpmOk = $false
            if (-not $usage) {
                $tpmStr = 'TPM pool unreported'
            }
            else {
                $lim = [int][double]$usage.limit
                $avail = $lim - [int][double]$usage.currentValue
                $tpmStr = "${avail}K of ${lim}K TPM"
                if ($avail -ge $FoundryTierTpmK) { $tpmOk = $true }
            }

            $ok = $catOk -and $tpmOk
            if ($ok) {
                $tierOk = $true
                # Candidates are listed best-first, so the first pass is the pick.
                if (-not $tierPick) { $tierPick = $spec }
            }
            $results += [pscustomobject]@{ Ok = $ok; Spec = $spec; Model = $model; CatStr = $catStr; TpmStr = $tpmStr }
        }

        foreach ($res in $results) {
            $msg = "Needed: $($res.Spec) + ${FoundryTierTpmK}K TPM  Available: $($res.CatStr); $($res.TpmStr)  SKU: OpenAI.$FoundrySku.$($res.Model)"
            if ($res.Ok) { Write-CheckResult PASS $Tier $msg }
            elseif ($tierOk) { Write-CheckResult INFO $Tier $msg }
            else { Write-CheckResult FAIL $Tier $msg }
        }
        if (-not $tierOk) {
            Write-Host "         No $Tier-tier model has catalog + TPM headroom — request a TPM increase or use a region offering one of: $($Candidates -join ' ')"
            Write-Host '         (TPM quota counts existing deployments in this subscription+region even when idle)'
        }
        if ($Tier -eq 'normal') { $script:FoundryNormalPick = $tierPick } else { $script:FoundryFastPick = $tierPick }
    }

    if (-not $Region) {
        Write-Step 'Capacity & quota checks — skipped (no region provided in the walkthrough)'
    }
    else {
        # Normalize ('East US' → eastus); reject unknown regions early.
        $regionInput = $Region
        $Region = ($Region -replace '\s', '').ToLowerInvariant()
        Write-Step "Capacity & quota checks (region: $Region)"
        $knownRegion = ((& az account list-locations --query "[?name=='$Region'] | [0].name" -o tsv 2>$null) | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { $knownRegion = '' }
        if (-not $knownRegion) {
            Write-CheckResult FAIL 'region' "'$regionInput' is not a known Azure region (expected a name like eastus)"
        }
        else {
            # The usage/catalog APIs need these providers Registered; step 1's
            # registrations are async, so wait briefly.
            foreach ($ns in 'Microsoft.Compute', 'Microsoft.CognitiveServices') {
                for ($i = 0; $i -lt 45; $i++) {
                    $state = ((& az provider show --namespace $ns --query registrationState -o tsv 2>$null) | Out-String).Trim()
                    if ($state -eq 'Registered') { break }
                    Write-Host "  waiting for provider registration: $ns ($state)…"
                    Start-Sleep -Seconds 2
                }
            }

            # One compute-usage listing feeds the General Compute and GPU sections.
            $vmJson = & az vm list-usage --location $Region -o json 2>$null
            $vmRows = if ($LASTEXITCODE -eq 0 -and $vmJson) { $vmJson | ConvertFrom-Json } else { $null }

            Write-CheckSection 'General Compute quota'
            if (-not $vmRows) {
                Write-CheckResult WARN 'vCPU (region)' "Needed: $MinVcpusAvailable  Available: unknown (could not read compute usages)  SKU: Total Regional vCPUs (cores)"
                Write-CheckResult WARN 'vCPU (system)' "Needed: $AksSystemVmVcpus  Available: unknown (could not read compute usages)  SKU: $AksSystemVmSku ($AksSystemVmFamily)"
                $VcpuRegionStatus = 'WARN — could not read compute usages'
                $VcpuSystemStatus = 'WARN — could not read compute usages'
            }
            else {
                $cores = $vmRows | Where-Object { $_.name.value -eq 'cores' } | Select-Object -First 1
                if (-not $cores) {
                    Write-CheckResult WARN 'vCPU (region)' "Needed: $MinVcpusAvailable  Available: unknown (quota not reported)  SKU: Total Regional vCPUs (cores)"
                    $VcpuRegionStatus = 'WARN — quota not reported'
                }
                else {
                    $lim = [int]$cores.limit
                    $avail = $lim - [int]$cores.currentValue
                    if ($avail -ge $MinVcpusAvailable) {
                        Write-CheckResult PASS 'vCPU (region)' "Needed: $MinVcpusAvailable  Available: $avail of $lim  SKU: Total Regional vCPUs (cores)"
                        $VcpuRegionStatus = "PASS — $avail of $lim free (needs $MinVcpusAvailable)"
                    }
                    else {
                        Write-CheckResult FAIL 'vCPU (region)' "Needed: $MinVcpusAvailable  Available: $avail of $lim  SKU: Total Regional vCPUs (cores) — request an increase"
                        $VcpuRegionStatus = "FAIL — $avail of $lim free (needs $MinVcpusAvailable)"
                    }
                }

                # Static AKS system node (Standard_D8s_v3 — ent-platform aks_vm_size)
                # draws from the DSv3 family pool, separate from the regional total.
                $sys = $vmRows | Where-Object { $_.name.value -eq $AksSystemVmFamily } | Select-Object -First 1
                if (-not $sys) {
                    Write-CheckResult WARN 'vCPU (system)' "Needed: $AksSystemVmVcpus  Available: unknown (quota not reported)  SKU: $AksSystemVmSku ($AksSystemVmFamily)"
                    $VcpuSystemStatus = 'WARN — quota not reported'
                }
                else {
                    $lim = [int]$sys.limit
                    $avail = $lim - [int]$sys.currentValue
                    if ($avail -ge $AksSystemVmVcpus) {
                        Write-CheckResult PASS 'vCPU (system)' "Needed: $AksSystemVmVcpus  Available: $avail of $lim  SKU: $AksSystemVmSku ($AksSystemVmFamily)"
                        $VcpuSystemStatus = "PASS — $avail of $lim free (needs $AksSystemVmVcpus, $AksSystemVmSku)"
                    }
                    else {
                        Write-CheckResult FAIL 'vCPU (system)' "Needed: $AksSystemVmVcpus  Available: $avail of $lim  SKU: $AksSystemVmSku ($AksSystemVmFamily) — request a 'Standard DSv3 Family vCPUs' increase"
                        $VcpuSystemStatus = "FAIL — $avail of $lim free (needs $AksSystemVmVcpus, $AksSystemVmSku)"
                    }
                }
            }

            Write-CheckSection 'GPU quota (only ONE family needs to pass)'
            if (-not $vmRows) {
                Write-CheckResult WARN 'GPU' "could not read compute usages for $Region — T4/A10 availability unknown"
            }
            else {
                # At least one T4/A10 family must fit its baseline card count. Short
                # families print INFO when another covers it, FAIL only when none does.
                $gpuOk = $false
                $gpuResults = @()
                foreach ($spec in $GpuFamilies) {
                    $minV = $spec.Cards * $spec.VcpusPerCard
                    $row = $vmRows | Where-Object { $_.name.value -eq $spec.Family } | Select-Object -First 1
                    if (-not $row) {
                        $gpuResults += [pscustomobject]@{ Spec = $spec; MinV = $minV; Avail = $null; AvailStr = 'not offered' }
                        continue
                    }
                    $avail = [int]$row.limit - [int]$row.currentValue
                    $gpuResults += [pscustomobject]@{ Spec = $spec; MinV = $minV; Avail = $avail; AvailStr = "$avail of $([int]$row.limit)" }
                    if ($avail -ge $minV) {
                        $gpuOk = $true
                        $GpuPassedSkus += "$($spec.Family) $($spec.Label -replace '^GPU ', '')"
                    }
                }
                foreach ($res in $gpuResults) {
                    $gpuMsg = "Needed: $($res.MinV) vCPUs ($($res.Spec.Cards) cards × $($res.Spec.VcpusPerCard) vCPU/card)  Available: $($res.AvailStr)  SKU: $($res.Spec.Family)"
                    if ($null -ne $res.Avail -and $res.Avail -ge $res.MinV) {
                        Write-CheckResult PASS $res.Spec.Label $gpuMsg
                    }
                    elseif ($gpuOk) {
                        Write-CheckResult INFO $res.Spec.Label $gpuMsg
                    }
                    else {
                        Write-CheckResult FAIL $res.Spec.Label $gpuMsg
                    }
                }
                if (-not $gpuOk) {
                    Write-Host "         The Ent serving baseline needs $GpuT4Cards full T4 cards (4 chat replicas + 1 embeddings) or $GpuA10Cards full A10 cards (2 chat replicas + 1 embeddings)."
                    Write-Host '         Request a quota increase on one of these GPU families (Azure portal → Quotas → Compute):'
                    foreach ($spec in $GpuFamilies) {
                        Write-Host "           - $($spec.Family) ($($spec.Label)): >= $($spec.Cards * $spec.VcpusPerCard) vCPUs for $($spec.Cards) cards — $($spec.Skus)"
                    }
                }
            }

            Write-CheckSection 'Foundry quota (only ONE model per tier needs to pass)'
            # One catalog + one usage listing serve every candidate below.
            $catalogJson = & az cognitiveservices model list -l $Region --query "[].{n:model.name,v:model.version}" -o json 2>$null
            $script:FoundryCatalog = if ($LASTEXITCODE -eq 0 -and $catalogJson) { $catalogJson | ConvertFrom-Json } else { @() }
            $usagesJson = & az cognitiveservices usage list -l $Region -o json 2>$null
            $script:FoundryUsages = if ($LASTEXITCODE -eq 0 -and $usagesJson) { $usagesJson | ConvertFrom-Json } else { @() }
            Test-TierModels -Tier 'normal' -Candidates $FoundryNormalModels
            Test-TierModels -Tier 'fast'   -Candidates $FoundryFastModels
        }

        if ($script:QuotaFails -gt 0) {
            if (-not [Console]::IsInputRedirected) {
                Write-Host ''
                $cont = Read-Host "Capacity checks reported $($script:QuotaFails) failure(s). Continue with setup anyway? [y/N]"
                if ($cont -notmatch '^[Yy]$') {
                    Write-Host 'Aborted before creating the deploy role/identity — fix quota/region and re-run.'
                    exit 1
                }
            }
            else {
                Write-Warning "capacity checks reported $($script:QuotaFails) failure(s); continuing (non-interactive run)."
            }
        }
        elseif ($script:QuotaWarns -gt 0) {
            Write-Host '  (warnings above are advisory — a value could not be verified; continuing)'
        }
    }

    # ── 3. Custom role definition ───────────────────────────────────────────────
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
        # Reconcile so re-runs pick up new Actions. A role manually broadened to
        # other subscriptions can fail with LinkedAuthorizationFailed — warn and
        # continue; -RoleName manages a separate single-subscription role instead.
        # Raw az (not Invoke-Az) so the real error can be surfaced.
        $updateOutput = & az role definition update --role-definition "@$rolePath" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  updated existing role definition '$RoleName'"
        }
        else {
            # Show az's real error — auth/malformed-role failures land here too.
            Write-Host "  WARNING: could not update role definition '$RoleName'; leaving it as-is. If this is a"
            Write-Host "           shared multi-subscription role you lack write on (LinkedAuthorizationFailed),"
            Write-Host "           re-run with -RoleName <name> for a separate single-subscription role. az error:"
            Write-Host (($updateOutput | Out-String).TrimEnd())
        }
    }
    else {
        Invoke-Az role definition create --role-definition "@$rolePath" | Out-Null
        Write-Host '  created role definition'
    }

    # ── 4. App registration + service principal ─────────────────────────────────
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

    # ── 5. Federated identity credentials (keyless) ─────────────────────────────
    function EnsureFic {
        param([string] $Name, [string] $Issuer, [string] $Subject)
        # Azure keys uniqueness on issuer+subject; match that combo (name may differ).
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

    # Customers trust ONLY the Ent Home (EKS) deploy path — no GitHub Actions trust.
    Write-Step "Configuring federated credential (no client secret) — EKS issuer: $EksOidcIssuer"
    EnsureFic -Name 'ent-home-eks-federated' -Issuer $EksOidcIssuer -Subject $DeploySaSubject

    # ── 6. Role assignment with ABAC privilege-escalation guard ─────────────────
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

    # ── 7. OpenSearch app registration + service principal ──────────────────────
    Write-Step "Ensuring OpenSearch app registration: $SpName-opensearch"
    # Dev gets its own identifier URI so its OpenSearch app stays isolated from home's.
    $osUri = "api://$TenantId/opensearch"
    if ($IsDev) { $osUri = "$osUri-dev" }
    $osAppId = Invoke-Az ad app list --display-name "$SpName-opensearch" --query "[0].appId" -o tsv
    if (-not $osAppId) {
        # Fall back to the unique identifier URI (display name may differ).
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

    # Blank tenant details show "(not provided)" and are listed in a closing note.
    $missing = @()
    if (-not $TenantName) { $missing += 'tenant name' }
    if (-not $Region)     { $missing += 'region' }
    if (-not $SsoDomains) { $missing += 'sso domains' }
    if (-not $Superusers) { $missing += 'superusers' }

    $dispName       = if ($TenantName) { $TenantName } else { '(not provided)' }
    $dispRegion     = if ($Region)     { $Region }     else { '(not provided)' }
    $dispSso        = if ($SsoDomains) { $SsoDomains } else { '(not provided)' }
    $dispSuperusers = if ($Superusers) { $Superusers } else { '(not provided)' }

    if (-not $Region) {
        $dispQuotaOverall  = '(not checked — no region provided)'
        $dispVcpuRegion    = '(not checked — no region provided)'
        $dispVcpuSystem    = '(not checked — no region provided)'
        $dispGpuSkus       = '(not checked — no region provided)'
        $dispFoundryNormal = '(not checked — no region provided)'
        $dispFoundryFast   = '(not checked — no region provided)'
    }
    else {
        $dispQuotaOverall = if ($script:QuotaFails -gt 0) {
            "FAIL — $($script:QuotaFails) blocking quota failure(s); deployment blocked until resolved"
        }
        elseif ($script:QuotaWarns -gt 0) {
            "PASS — no blocking failures ($($script:QuotaWarns) advisory warning(s))"
        }
        else {
            'PASS — all quota checks passed'
        }
        $dispVcpuRegion    = if ($VcpuRegionStatus) { $VcpuRegionStatus } else { '(not checked)' }
        $dispVcpuSystem    = if ($VcpuSystemStatus) { $VcpuSystemStatus } else { '(not checked)' }
        $dispGpuSkus       = if ($GpuPassedSkus.Count -gt 0) { $GpuPassedSkus -join ', ' } else { '(none passed — see capacity checks)' }
        $dispFoundryNormal = if ($FoundryNormalPick) { $FoundryNormalPick } else { '(none passed — see capacity checks)' }
        $dispFoundryFast   = if ($FoundryFastPick)   { $FoundryFastPick }   else { '(none passed — see capacity checks)' }
    }

    $bar = '=' * 80
    Write-Host ''
    Write-Host '✓ Setup complete.' -ForegroundColor Green
    Write-Host ''
    Write-Host $bar
    Write-Host ''
    Write-Host 'Give this information back to your Ent contact to finish setting up your tenant:'
    Write-Host ''
    Write-Host "  cloud provider   : AZURE"
    Write-Host "  tenant name      : $dispName"
    Write-Host "  region           : $dispRegion"
    Write-Host "  sso domains      : $dispSso"
    Write-Host "  superusers       : $dispSuperusers"
    Write-Host ''
    Write-Host "  capacity check results:"
    Write-Host "    overall        : $dispQuotaOverall"
    Write-Host "    vcpu (region)  : $dispVcpuRegion"
    Write-Host "    vcpu (system)  : $dispVcpuSystem"
    Write-Host "    gpu skus       : $dispGpuSkus"
    Write-Host "    foundry normal : $dispFoundryNormal"
    Write-Host "    foundry fast   : $dispFoundryFast"
    Write-Host ''
    Write-Host "  cloud provider details (subscription / Entra tenant / app client):"
    Write-Host "    subscriptionId : $Subscription"
    Write-Host "    tenantId       : $TenantId"
    Write-Host "    clientId       : $entAppId"
    Write-Host ''
    Write-Host $bar
    Write-Host ''
    Write-Host 'Reference (diagnostics):'
    Write-Host ''
    Write-Host "  service_principal_object_id            : $entSpObjectId"
    Write-Host "  role_definition_name                   : $RoleName"
    Write-Host "  role_definition_id                     : $roleDefId"
    Write-Host "  opensearch_client_id                   : $osAppId"
    Write-Host "  opensearch_identifier_uri              : $osUri"
    Write-Host "  opensearch_service_principal_object_id : $osSpObjectId"

    if ($missing.Count -gt 0) {
        Write-Warning ("these details were not provided: {0}. Re-run the script to enter them, or send them to your Ent contact separately." -f ($missing -join ', '))
    }
}
finally {
    Remove-Item -Recurse -Force -Path $workdir -ErrorAction SilentlyContinue
}
