# azure-ent-deploy-role

One-time, manual setup that creates the Ent Security deployment identity in a
customer Azure subscription. It runs entirely through the **Azure CLI (`az`)** —
no Terraform/OpenTofu required. Two equivalent versions are provided:
**`setup.sh`** (bash — macOS/Linux) and **`setup.ps1`** (PowerShell 7+ — cross-platform).

## What it creates

Both `setup.sh` and `setup.ps1` provision, idempotently:

- **Capacity & quota checks** run first against your chosen region — regional
  vCPU quota (≥ 150 free), DSv3-family quota for the static AKS system node
  (`Standard_D8s_v3`), NVIDIA T4/A10 GPU vCPU quota sized per silicon for the
  serving baseline — **5 full T4 cards** (4 vLLM chat replicas + 1 TEI
  embeddings; ≥ 20 `NCASt4_v3` vCPUs) or **3 full A10 cards** (2 chat replicas
  + 1 TEI, since A10's bf16/batch-32 profile needs fewer pods; ≥ 108
  `NVADSA10v5` or ≥ 96 `NCADSA10v4` vCPUs); a failure lists the exact quota
  families/SKUs to request — and Azure AI Foundry catalog availability + TPM
  headroom for the benchmark-approved serving models, where any **one** model
  per tier is enough: normal tier `gpt-5.1`, `gpt-5.2`, `gpt-4.1`, `gpt-5`, or
  `gpt-5-mini`; fast tier `gpt-4.1-mini` or `gpt-5-nano` (pinned versions where
  established). Any failure prompts before anything is created. Note: TPM quota
  counts allocations held by *existing* deployments of the model in the
  subscription+region, even idle ones.
- A **custom role definition** (`Ent Platform Deploy Role`) scoped to your subscription.
- An **app registration + service principal** (`ent-platform-deploy`) that Ent authenticates as.
- **Two keyless federated identity credentials** — no client secret is ever created:
  - **GitHub Actions OIDC** — Ent's `ent-platform` deploy workflow.
  - **EKS workload identity** — the Ent Home deploy job running in Ent's home-prod EKS cluster.
- A **role assignment** binding the role to the service principal, gated by an ABAC condition that blocks privilege escalation (see [Permissions](#permissions)).
- An **OpenSearch app registration + service principal** (`os_admin` / `os_reader` app roles).

## Prerequisites

- **Azure CLI** `az` >= 2.37 (needs `az ad app federated-credential`), authenticated with `az login`.
- Rights to create a custom role definition in the subscription **and** app registrations in the tenant — e.g. **Owner** + **Application Administrator**, or equivalent.
- To run `setup.ps1`: **PowerShell 7+** (`pwsh`). `setup.sh` needs bash.

## First-time setup

Run this once per Azure subscription you want Ent to deploy into, from an account
with **Owner** on the subscription plus rights to create app registrations in the
tenant (see [Prerequisites](#prerequisites)).

1. **Clone the repo and sign in to Azure:**

   ```bash
   git clone https://github.com/ent-security/azure-ent-deploy-role.git
   cd azure-ent-deploy-role
   az login
   ```

2. **Run the setup script:**

   ```bash
   # bash (macOS / Linux)
   ./setup.sh
   ```

   ```powershell
   # PowerShell 7+ (Windows / macOS / Linux)
   ./setup.ps1
   ```

   It walks you through everything up front:

   - **Subscription** — press Enter to accept your active az subscription, or
     type another ID. (You can also pass `--subscription` / `-Subscription` up
     front; that's required if you run the script non-interactively.)
   - **Tenant details** — tenant name, region, SSO domains, and superuser emails,
     which your Ent contact needs. Press Enter to skip any you don't have yet;
     you can re-run the script to fill them in. (The region also drives the
     capacity checks below — skipping it skips them.)
   - **Confirmation** — a final `Proceed? [y/N]` before it changes anything.

   It then registers the required resource providers, runs the **capacity &
   quota checks** against your region (vCPUs, T4/A10 GPUs, Foundry model
   TPM + catalog with pinned versions — failures prompt before anything is
   created), and creates the custom role, the `ent-platform-deploy` app
   registration + service principal, the two keyless federated credentials, the
   ABAC-gated role assignment, and the OpenSearch app. It is **idempotent** —
   safe to re-run; each step reconciles an existing object instead of failing.

3. **Copy the block it prints** when it finishes:

   ```
   ✓ Setup complete.

   ================================================================================

   Give this information back to your Ent contact to finish setting up your tenant:

     cloud provider   : AZURE
     tenant name      : Acme Prod
     region           : eastus
     sso domains      : acme.com,acme.io
     superusers       : admin@acme.com,sec@acme.com

     cloud provider details (subscription / Entra tenant / app client):
       subscriptionId : 00000000-0000-0000-0000-000000000000
       tenantId       : 66666666-7777-8888-9999-000000000000
       clientId       : 11111111-2222-3333-4444-555555555555

   ================================================================================
   ```

   The top four values are the answers you gave in the walkthrough; anything you
   skipped shows `(not provided)` (re-run the script to fill it in). The
   subscription / Entra tenant / app client IDs are derived automatically. The
   script also prints reference IDs (service-principal object ID, role definition,
   OpenSearch) below the block.

4. **Send that block to your Ent contact.** They use it to finish provisioning
   your tenant — you don't need to run anything else.

No client secret is ever created or stored — Ent authenticates through the
federated credentials (see [Authentication](#authentication-no-client-secret)).

### Options

| Flag | Description | Default |
|------|-------------|---------|
| `-s`, `--subscription` | Target Azure subscription ID; prompted for interactively when omitted (Enter accepts your active az subscription). Required as a flag for non-interactive runs. | _(prompted)_ |
| `--role-name` | Custom role display name | `Ent Platform Deploy Role` |
| `--sp-name` | App registration / service principal display name | `ent-platform-deploy` |
| `--github-repository` | GitHub repo (`owner/repo`) for the Actions OIDC credential | `ent-security/ent-platform` |
| `--github-ref` | Git ref for the Actions credential | `refs/heads/main` |
| `--env` | Ent home cluster the EKS credential trusts: `prod` or `dev`. `dev` provisions a separate `-dev` identity (see note). | `prod` |
| `--eks-oidc-issuer` | Explicit EKS OIDC issuer URL (advanced; not combinable with `--env`) | _(resolved from `--env`)_ |
| `--deploy-sa-subject` | Kubernetes service-account subject for the EKS credential | `system:serviceaccount:ent-home:ent-home-api` |

The **tenant details** for your Ent contact (tenant name, region, SSO domains,
superusers) aren't flags — the script prompts for them interactively during the
run (see [First-time setup](#first-time-setup)). They're customer choices that
can't be derived from Azure and don't change what the script provisions; skipped
values show `(not provided)` in the final block.

The table shows `setup.sh` flags; `setup.ps1` takes the same options as PowerShell
parameters — `-Subscription`, `-RoleName`, `-SpName`, `-GithubRepository`,
`-GithubRef`, `-Env`, `-EksOidcIssuer`, `-DeploySaSubject`.

For customer onboarding, **leave the EKS settings at their defaults** — every
customer trusts Ent's home-**prod** cluster. `--env dev` exists only for
Ent-internal testing against the home-dev cluster and must **never** be used for a
customer tenant; `--eks-oidc-issuer` is an escape hatch for any other cluster. The
`--deploy-sa-subject` default is a frozen, fleet-wide contract pinned by Ent.

`--env dev` provisions a **fully separate `ent-platform-deploy-dev` identity** — its
own app registration, service principal, federated credentials, and OpenSearch app
(`api://<tenant>/opensearch-dev`) — so internal dev testing never collides with the
home/prod deploy app. Pass `--sp-name` to override the app name.

## Authentication (no client secret)

The service principal is configured with **two federated identity credentials** —
both keyless. No client secret is ever created or stored.

1. **GitHub Actions OIDC** — issuer `https://token.actions.githubusercontent.com`, used by Ent's `ent-platform` deploy workflow. Scoped by `--github-repository` / `--github-ref`.
2. **EKS workload identity** — issuer selected by `--env` (default home-**prod**), used by the Ent Home deploy job running in Ent's home EKS cluster. The pod presents a projected service-account token (audience `api://AzureADTokenExchange`); Microsoft Entra exchanges it for an ARM access token in your tenant. The issuer and the subject (`--deploy-sa-subject`) are **exact-match** values — frozen, fleet-wide contracts.

Both credentials authenticate as the same service principal, so the two outputs
you paste into Ent onboarding (`application_client_id`, `tenant_id`) cover both paths.

## Running individual steps

`setup.sh` is the source of truth and the supported entry point; advanced
operators can read it and run the underlying `az` commands by hand. For example,
the EKS federated credential alone is:

```bash
APP_OBJECT_ID=$(az ad app list --display-name "ent-platform-deploy" --query "[0].id" -o tsv)

az ad app federated-credential create --id "$APP_OBJECT_ID" --parameters '{
  "name": "ent-home-eks-federated",
  "issuer": "https://oidc.eks.us-west-1.amazonaws.com/id/98DF15409F88BD228838D6794CA04EAD",
  "subject": "system:serviceaccount:ent-home:ent-home-api",
  "audiences": ["api://AzureADTokenExchange"]
}'
```

## Permissions

The custom role grants permissions to manage the following Azure services:

| Service | Resource Provider | Scope |
|---------|-------------------|-------|
| Resource Groups | `Microsoft.Resources` | CRUD |
| Virtual Network | `Microsoft.Network` | Full (VNet, Subnet, NSG, NAT, Public IP, App Gateway) |
| Private Endpoints | `Microsoft.Network` | Full (Private DNS, endpoints) |
| DNS Zones | `Microsoft.Network` | Full |
| AKS | `Microsoft.ContainerService` | Full |
| Container Registry | `Microsoft.ContainerRegistry` | Full |
| PostgreSQL Flexible Server | `Microsoft.DBforPostgreSQL` | Full |
| Redis | `Microsoft.Cache` | Full (classic Redis only) |
| Key Vault | `Microsoft.KeyVault` | Full (control + data plane: secrets, certificates, keys) |
| Storage Accounts | `Microsoft.Storage` | Full (control + data plane) |
| Service Bus | `Microsoft.ServiceBus` | Full (control + data plane) |
| AI Services | `Microsoft.CognitiveServices` | Full (control + data plane) |
| Managed Identity | `Microsoft.ManagedIdentity` | Full |
| Role Assignments | `Microsoft.Authorization` | Create + delete (ABAC-gated; see below) |
| Monitoring | `Microsoft.Insights` | Read-only |
| Log Analytics | `Microsoft.OperationalInsights` | Read-only |
| Compute (GPU capacity) | `Microsoft.Compute` | Read-only (VM SKUs + regional usage/quota, for the GPU serving-profile capability check) |

### Excluded permissions (privilege escalation prevention)

Only role *definition* writes are blocked outright:

- `Microsoft.Authorization/roleDefinitions/write`
- `Microsoft.Authorization/roleDefinitions/delete`

`Microsoft.Authorization/roleAssignments/write` **and** `/delete` are granted — Ent needs delete to replace role assignments when their parent resource changes (model swaps, managed-identity rotations, etc.). Escalation is blocked instead by an ABAC condition on the role assignment, which prevents the service principal from granting or removing **Owner**, **User Access Administrator**, or **Role Based Access Control Administrator**.

## Directory structure

```
azure-ent-deploy-role/
├── setup.sh          # bash (macOS / Linux)
├── setup.ps1         # PowerShell 7+
├── .gitignore
└── README.md
```
