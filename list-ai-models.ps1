#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
  List Azure OpenAI model candidates (with TPM quota) for an Ent deployment, so a
  customer can choose what to enter in the "Azure AI Model" (chat) and "Azure AI
  Fast Model" (fast) fields of the Ent Azure deployment configuration.
  PowerShell equivalent of list-ai-models.sh.

.DESCRIPTION
  Read-only: this script only QUERIES Azure (model availability + quota). It creates
  and changes nothing, so it is safe to run as often as needed.

  For the target subscription + region it prints, per tier, the candidate models
  that are BOTH deployable in that region AND have quota for the chosen SKU, with
  their limit / used / free TPM. The customer picks a model per tier and a capacity
  that fits under the free column, then tells Ent which models to deploy at what
  capacity.

  Quota and capacity share the same unit: thousands of TPM (1 = 1,000 tokens/min),
  the same value entered in the "Azure AI Capacity" fields. A tier's requested
  capacity must be <= that model's free quota.

  Prerequisites:
    - PowerShell 7+
    - Azure CLI (az), logged in (az login)
    - Read access to the subscription (Cognitive Services model list + usage)

.EXAMPLE
  ./list-ai-models.ps1 -Subscription 00000000-0000-0000-0000-000000000000 -Location eastus2

.EXAMPLE
  ./list-ai-models.ps1 -Subscription <sub> -Location centralus -Sku GlobalStandard
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory, HelpMessage = 'Target Azure subscription ID')]
    [string] $Subscription,

    [Parameter(Mandatory, HelpMessage = 'Azure region to check (e.g. eastus2, centralus)')]
    [string] $Location,

    [string] $Sku = 'GlobalStandard'   # the SKU Ent deploys (AzureModelSpec.DEFAULT_SKU)
)

$ErrorActionPreference = 'Stop'
# az calls are checked explicitly via Invoke-Az; never let a native command auto-throw.
$PSNativeCommandUseErrorActionPreference = $false

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'The Azure CLI (az) is not on PATH. Install it and run "az login".'
}

# Quiet az's warning-level chatter (see setup.ps1 for why this is set via the env var).
$env:AZURE_CORE_ONLY_SHOW_ERRORS = 'true'

function Write-Step { param([string] $Message) Write-Host "`n==> $Message" -ForegroundColor Cyan }

# Run az with the given args; throw on non-zero exit. Returns trimmed stdout.
function Invoke-Az {
    $output = & az @args
    if ($LASTEXITCODE -ne 0) { throw "az $($args -join ' ') failed (exit $LASTEXITCODE)" }
    if ($null -eq $output) { return '' }
    return (($output -join "`n").Trim())
}

# Azure's quota key drops the dash after "gpt" (gpt4.1-mini) while the deployable
# model name keeps it (gpt-4.1-mini). Normalize both sides to a comparable key.
function Get-Key { param([string] $Name) ($Name.ToLower() -replace '[.-]', '') }

Invoke-Az account set --subscription $Subscription | Out-Null
$subName = Invoke-Az account show --query name -o tsv

# Curated candidates per tier. Chat = capable, reasoning-grade general models for the
# balanced/precise tiers; fast = small non-reasoning models for the hot annotation
# path; embedding is always deployed (defaults to text-embedding-3-small). These are
# the model families Ent's tiers are built around — a customer wanting something else
# can still read its quota row and ask.
$chatCandidates  = @('gpt-4.1', 'gpt-5', 'gpt-5-mini', 'gpt-5.1', 'gpt-5.2')
$fastCandidates  = @('gpt-4.1-mini', 'gpt-4o-mini', 'gpt-4.1-nano', 'gpt-5-nano')
$embedCandidates = @('text-embedding-3-small', 'text-embedding-3-large')

Write-Step 'Azure OpenAI model candidates'
Write-Host "    subscription : $subName ($Subscription)"
Write-Host "    region       : $Location"
Write-Host "    sku          : $Sku"

# ── Deployable models in the region (no Cognitive Services account required) ──
# key -> newest available version, for models offered under $Sku.
$modelVer = @{}
$modelTsv = Invoke-Az cognitiveservices model list -l $Location `
    --query "[?model.format=='OpenAI'].[model.name, model.version, join(',', model.skus[].name)]" -o tsv
foreach ($line in ($modelTsv -split "`r?`n")) {
    if (-not $line.Trim()) { continue }
    $parts = $line -split "`t"
    if ($parts.Count -lt 3) { continue }
    $name = $parts[0]; $version = $parts[1]; $skus = $parts[2]
    if (",$skus," -notlike "*,$Sku,*") { continue }   # offered under this SKU?
    $key = Get-Key $name
    # Keep the newest version if a model lists several (YYYY-MM-DD sorts as a string).
    if (-not $modelVer.ContainsKey($key) -or $version -gt $modelVer[$key]) { $modelVer[$key] = $version }
}

# ── Quota for the chosen SKU ──────────────────────────────────────────────────
# key -> @{ Limit; Used } in thousands of TPM.
$quota = @{}
$prefix = "OpenAI.$Sku."
$usageTsv = Invoke-Az cognitiveservices usage list -l $Location `
    --query "[?starts_with(name.value, '$prefix')].[name.value, limit, currentValue]" -o tsv
foreach ($line in ($usageTsv -split "`r?`n")) {
    if (-not $line.Trim()) { continue }
    $parts = $line -split "`t"
    if ($parts.Count -lt 3) { continue }
    $key = Get-Key ($parts[0].Substring($prefix.Length))
    $quota[$key] = @{ Limit = [int][double] $parts[1]; Used = [int][double] $parts[2] }
}

function Show-Tier {
    param([string] $Title, [string] $Field, [string[]] $Models)
    Write-Host ''
    Write-Host "  $Title" -ForegroundColor Cyan -NoNewline
    Write-Host "  → the `"$Field`" field"
    '    {0,-26} {1,-12} {2,10} {3,10} {4,10}   {5}' -f 'MODEL', 'VERSION', 'LIMIT', 'USED', 'FREE', 'VALUE TO PASTE' | Write-Host
    $any = $false
    foreach ($m in $Models) {
        $key = Get-Key $m
        # Show only models that are both deployable here and carry usable quota.
        if (-not $modelVer.ContainsKey($key) -or -not $quota.ContainsKey($key)) { continue }
        $ver = $modelVer[$key]
        $lim = $quota[$key].Limit
        $used = $quota[$key].Used
        if ($lim -le 0) { continue }
        $free = $lim - $used
        '    {0,-26} {1,-12} {2,10} {3,10} {4,10}   {5}@{6}' -f $m, $ver, $lim, $used, $free, $m, $ver | Write-Host
        $any = $true
    }
    if (-not $any) { Write-Host "    (no candidate models available with $Sku quota in $Location)" }
}

Show-Tier -Title 'CHAT / reasoning tier' -Field 'Azure AI Model' -Models $chatCandidates
Show-Tier -Title 'FAST tier' -Field 'Azure AI Fast Model' -Models $fastCandidates
Show-Tier -Title 'EMBEDDING (always deployed)' -Field 'Azure AI Embedding Model' -Models $embedCandidates

Write-Host @"

  LIMIT / USED / FREE are in thousands of TPM — the same unit as the Azure AI
  Capacity fields. The capacity you request for a tier must be <= that model's FREE.
  The @version suffix is optional; drop it to let Azure pick the current default.

  Reply to Ent with, per tier: <model> at <capacity>. For example:
    chat: gpt-5-mini@2025-08-07 at 15000
    fast: gpt-4.1-mini@2025-04-14 at 100000
"@
