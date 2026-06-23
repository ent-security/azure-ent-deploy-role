# azure-ent-deploy-role

One-time, manual setup that creates the Ent Security deployment identity in a
customer Azure subscription. It runs entirely through the **Azure CLI (`az`)** —
no Terraform/OpenTofu required.

## What it creates

`setup.sh` provisions, idempotently:

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

## Usage

```bash
./setup.sh --subscription <your-subscription-id>
```

The script is **idempotent** — safe to re-run. Each step checks for the existing
object before creating it, so a second run reconciles rather than failing.

When it finishes, paste the printed **`application_client_id`** and **`tenant_id`**
into the Azure connection panel in Ent onboarding, then click **Save & Test Connection**.

### Options

| Flag | Description | Default |
|------|-------------|---------|
| `-s`, `--subscription` | Target Azure subscription ID | _(required)_ |
| `--role-name` | Custom role display name | `Ent Platform Deploy Role` |
| `--sp-name` | App registration / service principal display name | `ent-platform-deploy` |
| `--github-repository` | GitHub repo (`owner/repo`) for the Actions OIDC credential | `ent-security/ent-platform` |
| `--github-ref` | Git ref for the Actions credential | `refs/heads/main` |
| `--eks-oidc-issuer` | EKS OIDC issuer URL for the workload-identity credential | `https://oidc.eks.us-west-1.amazonaws.com/id/98DF15409F88BD228838D6794CA04EAD` |
| `--deploy-sa-subject` | Kubernetes service-account subject for the EKS credential | `system:serviceaccount:ent-home:ent-home-api` |

The `eks-oidc-issuer` and `deploy-sa-subject` defaults are **frozen, fleet-wide
contracts pinned by Ent** — identical for every customer. Leave them at their
defaults unless Ent tells you otherwise.

## Authentication (no client secret)

The service principal is configured with **two federated identity credentials** —
both keyless. No client secret is ever created or stored.

1. **GitHub Actions OIDC** — issuer `https://token.actions.githubusercontent.com`, used by Ent's `ent-platform` deploy workflow. Scoped by `--github-repository` / `--github-ref`.
2. **EKS workload identity** — issuer `--eks-oidc-issuer`, used by the Ent Home deploy job running in Ent's home-prod EKS cluster. The pod presents a projected service-account token (audience `api://AzureADTokenExchange`); Microsoft Entra exchanges it for an ARM access token in your tenant. The issuer and the subject (`--deploy-sa-subject`) are **exact-match** values — frozen, fleet-wide contracts.

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

## Setup

1. Run `./setup.sh --subscription <your-subscription-id>`.
2. Open the Azure connection settings page in Ent.
3. Enter the **`application_client_id`** and **`tenant_id`** the script prints (plus your **Subscription ID**).
4. Click **Save & Test Connection**.

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
| Key Vault | `Microsoft.KeyVault` | Full (control + data plane) |
| Storage Accounts | `Microsoft.Storage` | Full (control + data plane) |
| Service Bus | `Microsoft.ServiceBus` | Full (control + data plane) |
| AI Services | `Microsoft.CognitiveServices` | Full (control + data plane) |
| Managed Identity | `Microsoft.ManagedIdentity` | Full |
| Role Assignments | `Microsoft.Authorization` | Create + delete (ABAC-gated; see below) |
| Monitoring | `Microsoft.Insights` | Read-only |
| Log Analytics | `Microsoft.OperationalInsights` | Read-only |

### Excluded permissions (privilege escalation prevention)

Only role *definition* writes are blocked outright:

- `Microsoft.Authorization/roleDefinitions/write`
- `Microsoft.Authorization/roleDefinitions/delete`

`Microsoft.Authorization/roleAssignments/write` **and** `/delete` are granted — Ent needs delete to replace role assignments when their parent resource changes (model swaps, managed-identity rotations, etc.). Escalation is blocked instead by an ABAC condition on the role assignment, which prevents the service principal from granting or removing **Owner**, **User Access Administrator**, or **Role Based Access Control Administrator**.

## Directory structure

```
azure-ent-deploy-role/
├── setup.sh
├── .gitignore
└── README.md
```
