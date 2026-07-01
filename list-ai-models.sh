#!/usr/bin/env bash
#
# List Azure OpenAI model candidates (with TPM quota) for an Ent deployment, so a
# customer can choose what to enter in the "Azure AI Model" (chat) and "Azure AI
# Fast Model" (fast) fields of the Ent Azure deployment configuration.
#
# Read-only: this script only QUERIES Azure (model availability + quota). It creates
# and changes nothing, so it is safe to run as often as needed.
#
# For the target subscription + region it prints, per tier, the candidate models
# that are BOTH deployable in that region AND have quota for the chosen SKU, with
# their limit / used / free TPM. The customer picks a model per tier and a capacity
# that fits under the free column, then tells Ent which models to deploy at what
# capacity.
#
# Quota and capacity share the same unit: thousands of TPM (1 = 1,000 tokens/min),
# the same value entered in the "Azure AI Capacity" fields. A tier's requested
# capacity must be <= that model's free quota.
#
# Prerequisites:
#   - az (Azure CLI), logged in (az login)
#   - Read access to the subscription (Cognitive Services model list + usage)
#
# Usage:
#   ./list-ai-models.sh --subscription <subscription-id> --location <region>
#   ./list-ai-models.sh -s <sub> -l eastus2 [--sku GlobalStandard]

set -euo pipefail

SUBSCRIPTION_ID=""
LOCATION=""
SKU="GlobalStandard"   # the SKU Ent deploys (AzureModelSpec.DEFAULT_SKU)

usage() {
  cat <<'USAGE'
List Azure OpenAI model candidates + TPM quota for an Ent deployment (read-only).

Usage:
  ./list-ai-models.sh --subscription <subscription-id> --location <region> [--sku <sku>]

Required:
  -s, --subscription <id>   Target Azure subscription ID.
  -l, --location <region>   Azure region to check (e.g. eastus2, centralus). Quota is
                            per-region, so this must match the intended deploy region.

Optional:
  --sku <sku>               Deployment SKU to report quota for. Default: GlobalStandard
                            (the SKU Ent deploys). Others: DataZoneStandard, Standard.
  -h, --help                Show this help.

Prints, per tier (chat / fast / embedding), the candidate models available in the
region with their TPM quota (limit / used / free, in thousands of TPM — the same
unit as the "Azure AI Capacity" fields). Pick a model per tier and a capacity that
fits under the free column, then tell Ent which to deploy.
USAGE
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--subscription)      SUBSCRIPTION_ID="$2"; shift 2 ;;
    -l|--location|--region) LOCATION="$2"; shift 2 ;;
    --sku)                  SKU="$2"; shift 2 ;;
    -h|--help)              usage 0 ;;
    *) echo "Unknown argument: $1" >&2; usage 1 ;;
  esac
done

if [[ -z "$SUBSCRIPTION_ID" ]]; then
  echo "ERROR: --subscription <subscription-id> is required." >&2
  usage 1
fi
if [[ -z "$LOCATION" ]]; then
  echo "ERROR: --location <region> is required." >&2
  usage 1
fi

if ! command -v az >/dev/null 2>&1; then
  echo "ERROR: the Azure CLI (az) is not on PATH. Install it and run 'az login'." >&2
  exit 1
fi

# Quiet az's warning-level chatter (see setup.sh for why this is set via the env
# var rather than the --only-show-errors global flag).
export AZURE_CORE_ONLY_SHOW_ERRORS=true
AZ=(az)

"${AZ[@]}" account set --subscription "$SUBSCRIPTION_ID"
SUB_NAME="$("${AZ[@]}" account show --query name -o tsv)"

# Curated candidates per tier. Chat = capable, reasoning-grade general models for the
# balanced/precise tiers; fast = small non-reasoning models for the hot annotation
# path; embedding is always deployed (defaults to text-embedding-3-small). These are
# the model families Ent's tiers are built around — a customer wanting something else
# can still read its quota row and ask.
CHAT_CANDIDATES=(gpt-4.1 gpt-5 gpt-5-mini gpt-5.1 gpt-5.2)
FAST_CANDIDATES=(gpt-4.1-mini gpt-4o-mini gpt-4.1-nano gpt-5-nano)
EMBED_CANDIDATES=(text-embedding-3-small text-embedding-3-large)

# Azure's quota key drops the dash after "gpt" (gpt4.1-mini) while the deployable
# model name keeps it (gpt-4.1-mini). Normalize both sides to a comparable key.
# (bash 3.2 has no associative arrays, so lookups go through awk over these tables.)
norm() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '.-'; }

log() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

log "Azure OpenAI model candidates"
printf '    subscription : %s (%s)\n' "$SUB_NAME" "$SUBSCRIPTION_ID"
printf '    region       : %s\n' "$LOCATION"
printf '    sku          : %s\n' "$SKU"

# ── Deployable models in the region (no Cognitive Services account required) ──
# One "key<TAB>version" line per model offered under $SKU. Normalization + the SKU
# filter run in awk (bash 3.2 mis-parses a `case` inside command substitution).
MODEL_TABLE="$(
  "${AZ[@]}" cognitiveservices model list -l "$LOCATION" \
    --query "[?model.format=='OpenAI'].[model.name, model.version, join(',', model.skus[].name)]" -o tsv \
  | awk -F'\t' -v sku="$SKU" '
      index("," $3 ",", "," sku ",") {           # offered under this SKU?
        key = tolower($1); gsub(/[.-]/, "", key);
        print key "\t" $2
      }')"

# ── Quota for the chosen SKU ──────────────────────────────────────────────────
# One "key<TAB>limit<TAB>used" line per model (limit/used in thousands of TPM).
QUOTA_TABLE="$(
  "${AZ[@]}" cognitiveservices usage list -l "$LOCATION" \
    --query "[?starts_with(name.value, 'OpenAI.$SKU.')].[name.value, limit, currentValue]" -o tsv \
  | awk -F'\t' -v pfx="OpenAI.$SKU." '
      {
        key = tolower(substr($1, length(pfx) + 1)); gsub(/[.-]/, "", key);
        lim = $2; sub(/\..*/, "", lim);           # 225000.0 -> 225000
        used = $3; sub(/\..*/, "", used);
        print key "\t" lim "\t" used
      }')"

# Newest deployable version for a key (empty if not deployable under $SKU here).
lookup_ver() { printf '%s\n' "$MODEL_TABLE" | awk -F'\t' -v k="$1" '$1==k{print $2}' | sort | tail -1; }
# "limit<TAB>used" for a key (empty if the SKU has no quota row for it).
lookup_quota() { printf '%s\n' "$QUOTA_TABLE" | awk -F'\t' -v k="$1" '$1==k{print $2"\t"$3; exit}'; }

print_tier() {
  local title="$1" field="$2"; shift 2
  printf '\n  \033[1m%s\033[0m  → the "%s" field\n' "$title" "$field"
  printf '    %-26s %-12s %10s %10s %10s   %s\n' "MODEL" "VERSION" "LIMIT" "USED" "FREE" "VALUE TO PASTE"
  local any=0 m key ver q lim used free
  for m in "$@"; do
    key="$(norm "$m")"
    ver="$(lookup_ver "$key")"
    q="$(lookup_quota "$key")"
    # Show only models that are both deployable here and carry usable quota.
    if [[ -z "$ver" || -z "$q" ]]; then continue; fi
    lim="${q%%$'\t'*}"
    used="${q##*$'\t'}"
    if [[ -z "$lim" || "$lim" -le 0 ]]; then continue; fi
    free=$(( lim - used ))
    printf '    %-26s %-12s %10s %10s %10s   %s@%s\n' "$m" "$ver" "$lim" "$used" "$free" "$m" "$ver"
    any=1
  done
  if [[ "$any" -eq 0 ]]; then
    printf '    (no candidate models available with %s quota in %s)\n' "$SKU" "$LOCATION"
  fi
  return 0
}

print_tier "CHAT / reasoning tier" "Azure AI Model" "${CHAT_CANDIDATES[@]}"
print_tier "FAST tier" "Azure AI Fast Model" "${FAST_CANDIDATES[@]}"
print_tier "EMBEDDING (always deployed)" "Azure AI Embedding Model" "${EMBED_CANDIDATES[@]}"

cat <<'NOTE'

  LIMIT / USED / FREE are in thousands of TPM — the same unit as the Azure AI
  Capacity fields. The capacity you request for a tier must be <= that model's FREE.
  The @version suffix is optional; drop it to let Azure pick the current default.

  Reply to Ent with, per tier: <model> at <capacity>. For example:
    chat: gpt-5-mini@2025-08-07 at 15000
    fast: gpt-4.1-mini@2025-04-14 at 100000
NOTE
