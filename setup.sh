#!/usr/bin/env bash
#
# One-time manual setup for the Ent Security deployment identity in a customer
# Azure subscription, using only the Azure CLI (`az`) — no OpenTofu/Terraform.
#
# Idempotent: safe to re-run. Each step checks for the existing object before
# creating it, so a second run reconciles rather than erroring.
#
# Steps:
#   1. Resource provider registrations
#   2. Capacity & quota checks — regional + DSv3 system-node vCPU quota, T4/A10
#      GPU quota (5 T4 or 3 A10 full cards), Foundry catalog + TPM for the
#      pinned tiers. Failures prompt before anything below is created.
#   3. Custom role definition ("Ent Platform Deploy Role")
#   4. App registration + service principal ("ent-platform-deploy")
#   5. Two keyless federated identity credentials — GitHub Actions OIDC + Ent
#      Home EKS workload identity (--env dev is Ent-internal only)
#   6. Role assignment, ABAC-gated to block granting/removing Owner, User
#      Access Administrator, and RBAC Administrator (escalation guard)
#   7. OpenSearch app registration + service principal (os_admin / os_reader)
#
# Prerequisites:
#   - az >= 2.37 (for `az ad app federated-credential`), logged in (`az login`)
#   - Rights to create custom role definitions in the subscription AND to create
#     Entra app registrations in the tenant (e.g. Owner + Application Administrator)
#
# Usage:
#   ./setup.sh [--subscription <subscription-id>] [overrides]
#
# Walks you through the subscription and tenant details, then prints one block
# to hand to your Ent contact. Non-interactive runs skip the prompts and
# require --subscription.

set -euo pipefail

# ── Frozen, fleet-wide contracts pinned by Ent (override only if you know why) ─
ROLE_NAME="Ent Platform Deploy Role"
ROLE_DESCRIPTION="Custom role that grants Ent permissions to deploy and manage infrastructure in this subscription"
SP_NAME=""            # default: ent-platform-deploy (suffixed -dev for --env dev)
GITHUB_REPOSITORY="ent-security/ent-platform"
GITHUB_REF="refs/heads/main"
DEPLOY_SA_SUBJECT="system:serviceaccount:ent-home:ent-home-api"

# Known Ent home-cluster EKS OIDC issuers. Customer tenants ALWAYS trust prod;
# dev is for Ent-internal testing only and must never be used for a customer.
PROD_EKS_OIDC_ISSUER="https://oidc.eks.us-west-1.amazonaws.com/id/98DF15409F88BD228838D6794CA04EAD"
DEV_EKS_OIDC_ISSUER="https://oidc.eks.us-west-1.amazonaws.com/id/B86CB0977AB2E6A4A50182E607F3B4D7"

# ── Capacity-check contracts (mirror ent-home-api validation + AzureModelSpec) ─
# Models are pinned name@version; a stale pin FAILs listing the region's versions.
MIN_VCPUS_AVAILABLE=150             # regional vCPU floor for an Ent deployment
AKS_SYSTEM_VM_SKU="Standard_D8s_v3" # static AKS system pool SKU — ent-platform deploy/tofu/azure/platform/variables.tf (aks_vm_size)
AKS_SYSTEM_VM_FAMILY="standardDSv3Family"  # quota family the system SKU draws from
AKS_SYSTEM_VM_VCPUS=8               # vCPUs one Standard_D8s_v3 system node needs
FOUNDRY_SKU="GlobalStandard"        # serving-tier deployment SKU (its TPM quota pool is checked)
FOUNDRY_TIER_TPM_K=250              # K TPM needed per tier (AzureModelSpec DEFAULT_CAPACITY)
FOUNDRY_NORMAL_MODEL="gpt-5.1"      # normal serving tier
FOUNDRY_NORMAL_VERSION="2025-11-13"
FOUNDRY_FAST_MODEL="gpt-5-nano"     # fast serving tier
FOUNDRY_FAST_VERSION="2025-08-07"

# Baseline GPU cards per silicon: T4 = 4 vLLM chat replicas + 1 TEI (the
# decode-bound T4 tier needs many shallow pods); A10 = 2 + 1 (E4B-bf16 batch-32
# profile — GpuProfile.A10_E4B_BF16 — matches 4 T4s). Sources: ent-platform
# production-stack-models values.yaml + tei-embeddings chart.
GPU_T4_CARDS=5
GPU_A10_CARDS=3
# T4/A10 quota families; vCPUs/card = cheapest FULL-card VM (fractional A10
# SKUs don't count). Format: label|family|cards|vCPUs per card|VM SKUs
GPU_FAMILIES=(
  "GPU (T4 v3)|standardNCASt4v3Family|${GPU_T4_CARDS}|4|NC4as_T4_v3 (4 vCPU, 1 T4), NC8as_T4_v3 (8), NC16as_T4_v3 (16), NC64as_T4_v3 (64, 4 T4)"
  "GPU (A10 v5)|standardNVADSA10v5Family|${GPU_A10_CARDS}|36|NV36ads_A10_v5 (36 vCPU, 1 A10; NV6/12/18ads are fractional cards), NV72ads_A10_v5 (72, 2 A10)"
  "GPU (A10 v4)|standardNCADSA10v4Family|${GPU_A10_CARDS}|32|NC32ads_A10_v4 (32 vCPU, 1 A10; NC8/16ads are fractional cards)"
)

EKS_ENV=""            # --env prod|dev  (defaults to prod)
EKS_OIDC_ISSUER=""    # explicit --eks-oidc-issuer override (advanced; not combinable with --env)

SUBSCRIPTION_ID=""

# ── Tenant details (prompted below; blank on non-interactive runs) ────────────
TENANT_NAME=""
TENANT_REGION=""
SSO_DOMAINS=""
SUPERUSERS=""

# Built-in roles the deploy SP must NOT be able to assign or remove (escalation paths).
readonly FORBIDDEN_ROLE_GUIDS="8e3af657-a8ff-443c-a75c-2fe8c4bcb635, 18d7d88d-d35e-4fb5-a5c3-7773c20a72d9, f58310d9-a9f6-439a-9e8d-f62e7b41a168"

usage() {
  cat <<'USAGE'
One-time manual setup for the Ent Security deployment identity (Azure CLI only).

Usage:
  ./setup.sh [--subscription <subscription-id>] [overrides]

Subscription:
  -s, --subscription <id>     Target Azure subscription ID. Prompted for when
                              omitted (Enter accepts your active az subscription).
                              Required as a flag for non-interactive runs.

Overrides (frozen contracts — change only if you know why):
  --role-name <name>          Custom role display name.
  --sp-name <name>            App registration / service principal display name.
  --github-repository <o/r>   GitHub repo for the Actions OIDC federated credential.
  --github-ref <ref>          Git ref for the Actions federated credential.
  --env <prod|dev>            Ent home cluster the EKS credential trusts (default:
                              prod). 'dev' is Ent-internal only — never a customer.
  --eks-oidc-issuer <url>     Explicit EKS OIDC issuer URL (advanced; not
                              combinable with --env).
  --deploy-sa-subject <sub>   Kubernetes service-account subject for the EKS credential.
  -h, --help                  Show this help.

The script then walks you through the subscription and your tenant details (name,
region, SSO domains, superusers) and prints one block to hand back to your Ent contact.
USAGE
  exit "${1:-0}"
}

# Bold-green Ent rune + "ENT" banner (skipped for --help).
print_logo() {
  printf '\033[1;32m'
  cat <<'LOGO'

  ██    ██     ███████╗ ███╗   ██╗ ████████╗
  ██  ██       ██╔════╝ ████╗  ██║ ╚══██╔══╝
  ████  ██     █████╗   ██╔██╗ ██║    ██║
  ██  ██       ██╔══╝   ██║╚██╗██║    ██║
  ████         ███████╗ ██║ ╚████║    ██║
  ██           ╚══════╝ ╚═╝  ╚═══╝    ╚═╝
LOGO
  printf '\033[0m'
  printf '  Ent Security — Azure deployment identity setup\n'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--subscription)         SUBSCRIPTION_ID="$2"; shift 2 ;;
    --role-name)               ROLE_NAME="$2"; shift 2 ;;
    --sp-name)                 SP_NAME="$2"; shift 2 ;;
    --github-repository)       GITHUB_REPOSITORY="$2"; shift 2 ;;
    --github-ref)              GITHUB_REF="$2"; shift 2 ;;
    --env)                     EKS_ENV="$2"; shift 2 ;;
    --eks-oidc-issuer)         EKS_OIDC_ISSUER="$2"; shift 2 ;;
    --deploy-sa-subject)       DEPLOY_SA_SUBJECT="$2"; shift 2 ;;
    -h|--help)                 usage 0 ;;
    *) echo "Unknown argument: $1" >&2; usage 1 ;;
  esac
done

print_logo

# An explicit --eks-oidc-issuer wins; otherwise --env picks. Mutually exclusive.
if [[ -n "$EKS_OIDC_ISSUER" && -n "$EKS_ENV" ]]; then
  echo "ERROR: pass either --env or --eks-oidc-issuer, not both." >&2
  exit 1
fi
if [[ -z "$EKS_OIDC_ISSUER" ]]; then
  case "${EKS_ENV:-prod}" in
    prod) EKS_OIDC_ISSUER="$PROD_EKS_OIDC_ISSUER" ;;
    dev)  EKS_OIDC_ISSUER="$DEV_EKS_OIDC_ISSUER" ;;
    *)    echo "ERROR: --env must be 'prod' or 'dev' (got '$EKS_ENV')." >&2; exit 1 ;;
  esac
fi
EKS_ISSUER_RE='^https://oidc\.eks\.[a-z0-9-]+\.amazonaws\.com/id/[A-F0-9]+$'
if [[ ! "$EKS_OIDC_ISSUER" =~ $EKS_ISSUER_RE ]]; then
  echo "ERROR: EKS issuer must look like https://oidc.eks.<region>.amazonaws.com/id/<OIDC_ID>; got: $EKS_OIDC_ISSUER" >&2
  exit 1
fi
IS_DEV=false
if [[ "$EKS_OIDC_ISSUER" == "$DEV_EKS_OIDC_ISSUER" ]]; then
  IS_DEV=true
  echo "WARNING: trusting the Ent home-DEV EKS cluster — Ent-internal testing only; never a customer tenant." >&2
fi

# Dev gets a fully separate '-dev' identity so it never collides with home/prod.
if [[ -z "$SP_NAME" ]]; then
  SP_NAME="ent-platform-deploy"
  if [[ "$IS_DEV" == true ]]; then SP_NAME="${SP_NAME}-dev"; fi
fi

if ! command -v az >/dev/null 2>&1; then
  echo "ERROR: the Azure CLI (az) is not on PATH. Install it and run 'az login'." >&2
  exit 1
fi

# Quiet az warnings via env var — recent az rejects --only-show-errors when it
# precedes the command group, which a prefix array would do.
export AZURE_CORE_ONLY_SHOW_ERRORS=true
AZ=(az)

log() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

# ── Setup walkthrough ─────────────────────────────────────────────────────────
# TTY only: piped runs skip prompts (--subscription required; tenant details
# stay blank). "|| true" keeps set -e alive on EOF.
if [ -t 0 ]; then
  if [[ -z "$SUBSCRIPTION_ID" ]]; then
    log "Deployment target"
    # Enter accepts the active az subscription.
    CURRENT_SUB_ID="$("${AZ[@]}" account show --query id -o tsv 2>/dev/null || true)"
    if [[ -n "$CURRENT_SUB_ID" ]]; then
      CURRENT_SUB_NAME="$("${AZ[@]}" account show --query name -o tsv 2>/dev/null || true)"
      read -r -p "  Azure subscription ID [${CURRENT_SUB_ID} — ${CURRENT_SUB_NAME}]: " SUBSCRIPTION_ID || true
      SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-$CURRENT_SUB_ID}"
    else
      read -r -p "  Azure subscription ID: " SUBSCRIPTION_ID || true
    fi
  fi

  log "Tenant details (your Ent contact needs these)"
  printf '  Answer a few questions — press Enter to skip any you don'\''t have yet.\n\n'
  read -r -p "  Tenant name (e.g. Acme Prod): " TENANT_NAME || true
  read -r -p "  Azure region (e.g. eastus): " TENANT_REGION || true
  read -r -p "  SSO domains, comma-separated (e.g. acme.com,acme.io): " SSO_DOMAINS || true
  read -r -p "  Superuser emails, comma-separated (e.g. admin@acme.com): " SUPERUSERS || true
fi

if [[ -z "$SUBSCRIPTION_ID" ]]; then
  echo "ERROR: an Azure subscription ID is required — pass --subscription <id> on non-interactive runs." >&2
  usage 1
fi

# Confirm before mutating anything (TTY only; an explicit --subscription on a
# non-interactive run is the consent). Only y/Y proceeds — Enter/EOF aborts.
if [ -t 0 ]; then
  SUB_LABEL="$SUBSCRIPTION_ID"
  sub_name="$("${AZ[@]}" account show --subscription "$SUBSCRIPTION_ID" --query name -o tsv 2>/dev/null || true)"
  if [[ -n "$sub_name" ]]; then SUB_LABEL="$SUBSCRIPTION_ID — $sub_name"; fi
  printf '\n'
  read -r -p "Proceed with setup in subscription ${SUB_LABEL}? [y/N] " CONFIRM || true
  if [[ ! "${CONFIRM:-}" =~ ^[Yy]$ ]]; then
    echo "Aborted — nothing was changed." >&2
    exit 1
  fi
fi

SCOPE="/subscriptions/${SUBSCRIPTION_ID}"

"${AZ[@]}" account set --subscription "$SUBSCRIPTION_ID"
TENANT_ID="$("${AZ[@]}" account show --query tenantId -o tsv)"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# ── 1. Resource provider registration ────────────────────────────────────────
log "Registering resource providers"
for ns in \
  Microsoft.ContainerService Microsoft.DBforPostgreSQL Microsoft.Cache \
  Microsoft.ContainerRegistry Microsoft.ServiceBus Microsoft.Storage \
  Microsoft.KeyVault Microsoft.Network Microsoft.ManagedIdentity \
  Microsoft.Compute Microsoft.CognitiveServices Microsoft.Resources; do
  echo "  - $ns"
  "${AZ[@]}" provider register --namespace "$ns" --subscription "$SUBSCRIPTION_ID" >/dev/null
done

# ── 2. Capacity & quota checks ────────────────────────────────────────────────
# Verify the region can host an Ent deployment before creating any permission:
# regional + DSv3 system-node vCPUs, T4/A10 GPU cards, Foundry catalog + TPM.
# Mirrors ent-home-api's AzureDeploymentValidationService but FAILs (onboarding
# gate) instead of warning; az read errors still degrade to WARN (fail-open).
QUOTA_FAILS=0
QUOTA_WARNS=0
check_result() { # $1 PASS|WARN|FAIL|INFO, $2 label, $3 message; INFO never gates
  local color="32"
  case "$1" in
    WARN) color="33"; QUOTA_WARNS=$((QUOTA_WARNS + 1)) ;;
    FAIL) color="31"; QUOTA_FAILS=$((QUOTA_FAILS + 1)) ;;
    INFO) color="36" ;;
  esac
  printf '  \033[%sm%-4s\033[0m  %-14s %s\n' "$color" "$1" "$2" "$3"
}

check_section() { # $1 title — bold ='s bar with the title embedded
  local t=" $1 "
  local bar="============================================================================"
  local pad=$(( (${#bar} - ${#t}) / 2 ))
  printf '\n  \033[1m%s%s%s\033[0m\n' "${bar:0:pad}" "$t" "${bar:0:$(( ${#bar} - pad - ${#t} ))}"
}

check_model_capacity() { # $1 tier (normal|fast), $2 model, $3 pinned version
  local tier="$1" model="$2" version="$3" target versions versions_csv row cur lim avail
  target="${model}@${version}"

  # Regional catalog must offer the exact pinned version.
  versions="$("${AZ[@]}" cognitiveservices model list -l "$TENANT_REGION" \
      --query "[?model.name=='${model}'].model.version" -o tsv 2>/dev/null | sort -u || true)"
  versions_csv="$(echo "$versions" | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
  if [[ -z "$versions" ]]; then
    check_result FAIL "model (${tier})" "Needed: ${target}  Available: none  SKU: ${model} (Foundry catalog, ${TENANT_REGION})"
  elif grep -qx "$version" <<<"$versions"; then
    check_result PASS "model (${tier})" "Needed: ${target}  Available: ${versions_csv}  SKU: ${model} (Foundry catalog, ${TENANT_REGION})"
  else
    check_result FAIL "model (${tier})" "Needed: ${target}  Available: ${versions_csv}  SKU: ${model} (Foundry catalog, ${TENANT_REGION})"
  fi

  # TPM quota headroom in the deployment SKU's per-model pool.
  row="$("${AZ[@]}" cognitiveservices usage list -l "$TENANT_REGION" \
      --query "[?name.value=='OpenAI.${FOUNDRY_SKU}.${model}'] | [0].[currentValue,limit]" -o tsv 2>/dev/null || true)"
  if [[ -z "$row" ]]; then
    check_result WARN "TPM (${tier})" "Needed: ${FOUNDRY_TIER_TPM_K}K TPM  Available: unknown (no ${FOUNDRY_SKU} pool reported)  SKU: ${target} (${FOUNDRY_SKU})"
    return
  fi
  cur="$(cut -f1 <<<"$row")"; cur="${cur%%.*}"
  lim="$(cut -f2 <<<"$row")"; lim="${lim%%.*}"
  avail=$((lim - cur))
  if [[ "$avail" -ge "$FOUNDRY_TIER_TPM_K" ]]; then
    check_result PASS "TPM (${tier})" "Needed: ${FOUNDRY_TIER_TPM_K}K TPM  Available: ${avail}K of ${lim}K  SKU: ${target} (${FOUNDRY_SKU})"
  else
    check_result FAIL "TPM (${tier})" "Needed: ${FOUNDRY_TIER_TPM_K}K TPM  Available: ${avail}K of ${lim}K  SKU: ${target} (${FOUNDRY_SKU})"
    echo "         (TPM quota is allocated to existing ${model} deployments in this subscription+region even when idle — delete/scale them or request a limit increase)"
  fi
}

if [[ -z "$TENANT_REGION" ]]; then
  log "Capacity & quota checks — skipped (no region provided in the walkthrough)"
else
  # Normalize ('East US' → eastus); reject unknown regions early.
  region_input="$TENANT_REGION"
  TENANT_REGION="$(printf '%s' "$TENANT_REGION" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  log "Capacity & quota checks (region: $TENANT_REGION)"
  known_region="$("${AZ[@]}" account list-locations --query "[?name=='${TENANT_REGION}'] | [0].name" -o tsv 2>/dev/null || true)"
  if [[ -z "$known_region" ]]; then
    check_result FAIL "region" "'${region_input}' is not a known Azure region (expected a name like eastus)"
  else
    # The usage/catalog APIs need these providers Registered; step 1's
    # registrations are async, so wait briefly.
    for ns in Microsoft.Compute Microsoft.CognitiveServices; do
      for _ in $(seq 1 45); do
        state="$("${AZ[@]}" provider show --namespace "$ns" --query registrationState -o tsv 2>/dev/null || true)"
        if [[ "$state" == "Registered" ]]; then break; fi
        echo "  waiting for provider registration: $ns (${state:-unknown})…"
        sleep 2
      done
    done

    # One compute-usage listing feeds the General Compute and GPU sections.
    vm_rows="$("${AZ[@]}" vm list-usage --location "$TENANT_REGION" --query "[].[name.value,currentValue,limit]" -o tsv 2>/dev/null || true)"

    check_section "General Compute quota"
    if [[ -z "$vm_rows" ]]; then
      check_result WARN "vCPU (region)" "Needed: ${MIN_VCPUS_AVAILABLE}  Available: unknown (could not read compute usages)  SKU: Total Regional vCPUs (cores)"
      check_result WARN "vCPU (system)" "Needed: ${AKS_SYSTEM_VM_VCPUS}  Available: unknown (could not read compute usages)  SKU: ${AKS_SYSTEM_VM_SKU} (${AKS_SYSTEM_VM_FAMILY})"
    else
      cores_row="$(grep $'^cores\t' <<<"$vm_rows" | head -n1 || true)"
      if [[ -z "$cores_row" ]]; then
        check_result WARN "vCPU (region)" "Needed: ${MIN_VCPUS_AVAILABLE}  Available: unknown (quota not reported)  SKU: Total Regional vCPUs (cores)"
      else
        cur="$(cut -f2 <<<"$cores_row")"; cur="${cur%%.*}"
        lim="$(cut -f3 <<<"$cores_row")"; lim="${lim%%.*}"
        avail=$((lim - cur))
        if [[ "$avail" -ge "$MIN_VCPUS_AVAILABLE" ]]; then
          check_result PASS "vCPU (region)" "Needed: ${MIN_VCPUS_AVAILABLE}  Available: ${avail} of ${lim}  SKU: Total Regional vCPUs (cores)"
        else
          check_result FAIL "vCPU (region)" "Needed: ${MIN_VCPUS_AVAILABLE}  Available: ${avail} of ${lim}  SKU: Total Regional vCPUs (cores) — request an increase"
        fi
      fi

      # Static AKS system node (Standard_D8s_v3 — ent-platform aks_vm_size)
      # draws from the DSv3 family pool, separate from the regional total.
      sys_row="$(grep -i "^${AKS_SYSTEM_VM_FAMILY}"$'\t' <<<"$vm_rows" | head -n1 || true)"
      if [[ -z "$sys_row" ]]; then
        check_result WARN "vCPU (system)" "Needed: ${AKS_SYSTEM_VM_VCPUS}  Available: unknown (quota not reported)  SKU: ${AKS_SYSTEM_VM_SKU} (${AKS_SYSTEM_VM_FAMILY})"
      else
        cur="$(cut -f2 <<<"$sys_row")"; cur="${cur%%.*}"
        lim="$(cut -f3 <<<"$sys_row")"; lim="${lim%%.*}"
        avail=$((lim - cur))
        if [[ "$avail" -ge "$AKS_SYSTEM_VM_VCPUS" ]]; then
          check_result PASS "vCPU (system)" "Needed: ${AKS_SYSTEM_VM_VCPUS}  Available: ${avail} of ${lim}  SKU: ${AKS_SYSTEM_VM_SKU} (${AKS_SYSTEM_VM_FAMILY})"
        else
          check_result FAIL "vCPU (system)" "Needed: ${AKS_SYSTEM_VM_VCPUS}  Available: ${avail} of ${lim}  SKU: ${AKS_SYSTEM_VM_SKU} (${AKS_SYSTEM_VM_FAMILY}) — request a 'Standard DSv3 Family vCPUs' increase"
        fi
      fi
    fi

    check_section "GPU quota (only ONE family needs to pass)"
    if [[ -z "$vm_rows" ]]; then
      check_result WARN "GPU" "could not read compute usages for ${TENANT_REGION} — T4/A10 availability unknown"
    else
      # At least one T4/A10 family must fit its baseline card count. Short
      # families print INFO when another covers it, FAIL only when none does.
      gpu_ok=false
      gpu_results=()
      for spec in "${GPU_FAMILIES[@]}"; do
        IFS='|' read -r glabel fam cards per_card skus <<<"$spec"
        min_v=$((cards * per_card))
        row="$(grep -i "^${fam}"$'\t' <<<"$vm_rows" | head -n1 || true)"
        if [[ -z "$row" ]]; then
          gpu_results+=("${glabel}|${cards}|${min_v}|${per_card}|not offered|${fam}")
          continue
        fi
        cur="$(cut -f2 <<<"$row")"; cur="${cur%%.*}"
        lim="$(cut -f3 <<<"$row")"; lim="${lim%%.*}"
        avail=$((lim - cur))
        gpu_results+=("${glabel}|${cards}|${min_v}|${per_card}|${avail} of ${lim}|${fam}")
        if [[ "$avail" -ge "$min_v" ]]; then gpu_ok=true; fi
      done
      for res in "${gpu_results[@]}"; do
        IFS='|' read -r glabel cards min_v per_card avail_str fam <<<"$res"
        gpu_msg="Needed: ${min_v} vCPUs (${cards} cards × ${per_card} vCPU/card)  Available: ${avail_str}  SKU: ${fam}"
        avail_n="${avail_str%% *}"
        if [[ "$avail_n" =~ ^[0-9]+$ ]] && [[ "$avail_n" -ge "$min_v" ]]; then
          check_result PASS "$glabel" "$gpu_msg"
        elif [[ "$gpu_ok" == true ]]; then
          check_result INFO "$glabel" "$gpu_msg"
        else
          check_result FAIL "$glabel" "$gpu_msg"
        fi
      done
      if [[ "$gpu_ok" != true ]]; then
        echo "         The Ent serving baseline needs ${GPU_T4_CARDS} full T4 cards (4 chat replicas + 1 embeddings) or ${GPU_A10_CARDS} full A10 cards (2 chat replicas + 1 embeddings)."
        echo "         Request a quota increase on one of these GPU families (Azure portal → Quotas → Compute):"
        for spec in "${GPU_FAMILIES[@]}"; do
          IFS='|' read -r glabel fam cards per_card skus <<<"$spec"
          echo "           - ${fam} (${glabel}): >= $((cards * per_card)) vCPUs for ${cards} cards — ${skus}"
        done
      fi
    fi

    check_section "Foundry quota"
    check_model_capacity "normal" "$FOUNDRY_NORMAL_MODEL" "$FOUNDRY_NORMAL_VERSION"
    check_model_capacity "fast"   "$FOUNDRY_FAST_MODEL"   "$FOUNDRY_FAST_VERSION"
  fi

  if [[ "$QUOTA_FAILS" -gt 0 ]]; then
    if [ -t 0 ]; then
      printf '\n'
      read -r -p "Capacity checks reported ${QUOTA_FAILS} failure(s). Continue with setup anyway? [y/N] " CONTINUE_ANYWAY || true
      if [[ ! "${CONTINUE_ANYWAY:-}" =~ ^[Yy]$ ]]; then
        echo "Aborted before creating the deploy role/identity — fix quota/region and re-run." >&2
        exit 1
      fi
    else
      echo "WARNING: capacity checks reported ${QUOTA_FAILS} failure(s); continuing (non-interactive run)." >&2
    fi
  elif [[ "$QUOTA_WARNS" -gt 0 ]]; then
    echo "  (warnings above are advisory — a value could not be verified; continuing)"
  fi
fi

# ── 3. Custom role definition ─────────────────────────────────────────────────
log "Ensuring custom role definition: $ROLE_NAME"
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
  "AssignableScopes": ["${SCOPE}"]
}
JSON

if [[ -n "$("${AZ[@]}" role definition list --name "$ROLE_NAME" --scope "$SCOPE" --query "[0].name" -o tsv)" ]]; then
  # Reconcile so re-runs pick up new Actions. A role manually broadened to other
  # subscriptions can fail with LinkedAuthorizationFailed — warn and continue;
  # --role-name manages a separate single-subscription role instead.
  if update_err="$("${AZ[@]}" role definition update --role-definition "@$WORKDIR/role.json" 2>&1)"; then
    echo "  updated existing role definition '$ROLE_NAME'"
  else
    # Show az's real error — auth/malformed-role failures land here too.
    echo "  WARNING: could not update role definition '$ROLE_NAME'; leaving it as-is. If this is a shared" >&2
    echo "           multi-subscription role you lack write on (LinkedAuthorizationFailed), re-run with" >&2
    echo "           --role-name <name> for a separate single-subscription role. az error:" >&2
    printf '%s\n' "$update_err" | sed 's/^/             /' >&2
  fi
else
  "${AZ[@]}" role definition create --role-definition "@$WORKDIR/role.json" >/dev/null
  echo "  created role definition"
fi

# ── 4. App registration + service principal ───────────────────────────────────
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

# ── 5. Federated identity credentials (keyless) ───────────────────────────────
ensure_fic() {
  # $1 name, $2 issuer, $3 subject. Azure keys uniqueness on issuer+subject,
  # so match that combo (the name may differ).
  local existing
  existing="$("${AZ[@]}" ad app federated-credential list --id "$ENT_APP_OBJECT_ID" --query "[?issuer=='$2' && subject=='$3'].name | [0]" -o tsv)"
  if [[ -n "$existing" ]]; then
    echo "  fic for this issuer+subject already present (name: $existing) — skipping '$1'"
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

log "Configuring federated credentials (no client secret) — EKS issuer: $EKS_OIDC_ISSUER"
ensure_fic "ent-home-federated" "https://token.actions.githubusercontent.com" "repo:${GITHUB_REPOSITORY}:ref:${GITHUB_REF}"
ensure_fic "ent-home-eks-federated" "$EKS_OIDC_ISSUER" "$DEPLOY_SA_SUBJECT"

# ── 6. Role assignment with ABAC privilege-escalation guard ───────────────────
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

# ── 7. OpenSearch app registration + service principal ────────────────────────
log "Ensuring OpenSearch app registration: ${SP_NAME}-opensearch"
# Dev gets its own identifier URI so its OpenSearch app stays isolated from home's.
OS_URI="api://${TENANT_ID}/opensearch"
if [[ "$IS_DEV" == true ]]; then OS_URI="${OS_URI}-dev"; fi
OS_APP_ID="$("${AZ[@]}" ad app list --display-name "${SP_NAME}-opensearch" --query "[0].appId" -o tsv)"
if [[ -z "$OS_APP_ID" ]]; then
  # Fall back to the unique identifier URI (display name may differ).
  OS_APP_ID="$("${AZ[@]}" ad app list --identifier-uri "$OS_URI" --query "[0].appId" -o tsv)"
fi
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
    --identifier-uris "$OS_URI" \
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

# Blank tenant details show "(not provided)" and are listed in a closing note.
missing=()
if [[ -z "$TENANT_NAME"   ]]; then missing+=("tenant name"); fi
if [[ -z "$TENANT_REGION" ]]; then missing+=("region"); fi
if [[ -z "$SSO_DOMAINS"   ]]; then missing+=("sso domains"); fi
if [[ -z "$SUPERUSERS"    ]]; then missing+=("superusers"); fi

disp_name="${TENANT_NAME:-(not provided)}"
disp_region="${TENANT_REGION:-(not provided)}"
disp_sso="${SSO_DOMAINS:-(not provided)}"
disp_superusers="${SUPERUSERS:-(not provided)}"

cat <<OUT

$(printf '\033[1m✓ Setup complete.\033[0m')

================================================================================

Give this information back to your Ent contact to finish setting up your tenant:

  cloud provider   : AZURE
  tenant name      : ${disp_name}
  region           : ${disp_region}
  sso domains      : ${disp_sso}
  superusers       : ${disp_superusers}

  cloud provider details (subscription / Entra tenant / app client):
    subscriptionId : ${SUBSCRIPTION_ID}
    tenantId       : ${TENANT_ID}
    clientId       : ${ENT_APP_ID}

================================================================================

Reference (diagnostics):

  service_principal_object_id            : ${ENT_SP_OBJECT_ID}
  role_definition_name                   : ${ROLE_NAME}
  role_definition_id                     : ${ROLE_DEF_ID}
  opensearch_client_id                   : ${OS_APP_ID}
  opensearch_identifier_uri              : ${OS_URI}
  opensearch_service_principal_object_id : ${OS_SP_OBJECT_ID}
OUT

if [[ ${#missing[@]} -gt 0 ]]; then
  note_list="$(printf '%s, ' "${missing[@]}")"; note_list="${note_list%, }"
  printf '\n\033[1mNOTE:\033[0m these details were not provided: %s\n' "$note_list" >&2
  printf '      Re-run the script to enter them, or send them to your Ent contact separately.\n' >&2
fi
