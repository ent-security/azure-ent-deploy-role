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

2. **Run the setup script** against your target subscription:

   ```bash
   ./setup.sh --subscription <your-subscription-id>
   ```

   It registers the required resource providers and creates the custom role, the
   `ent-platform-deploy` app registration + service principal, the two keyless
   federated credentials, the ABAC-gated role assignment, and the OpenSearch app.
   It is **idempotent** — safe to re-run; each step reconciles an existing object
   instead of failing.

3. **Copy the two values it prints** when it finishes:

   ```
   ✓ Setup complete.

   Paste these two values into the Azure connection panel in Ent onboarding:

     application_client_id : 11111111-2222-3333-4444-555555555555
     tenant_id             : 66666666-7777-8888-9999-000000000000
   ```

   (It also prints the subscription ID, service-principal object ID, role
   definition, and OpenSearch IDs for reference.)

4. **In Ent**, open the Azure connection settings page, enter the
   **`application_client_id`**, **`tenant_id`**, and your **Subscription ID**, then
   click **Save & Test Connection**.

No client secret is ever created or stored — Ent authenticates through the
federated credentials (see [Authentication](#authentication-no-client-secret)).

### Options

| Flag | Description | Default |
|------|-------------|---------|
| `-s`, `--subscription` | Target Azure subscription ID | _(required)_ |
| `--role-name` | Custom role display name | `Ent Platform Deploy Role` |
| `--sp-name` | App registration / service principal display name | `ent-platform-deploy` |
| `--github-repository` | GitHub repo (`owner/repo`) for the Actions OIDC credential | `ent-security/ent-platform` |
| `--github-ref` | Git ref for the Actions credential | `refs/heads/main` |
| `--env` | Ent home cluster the EKS credential trusts: `prod` or `dev`. `dev` provisions a separate `-dev` identity (see note). | `prod` |
| `--eks-oidc-issuer` | Explicit EKS OIDC issuer URL (advanced; not combinable with `--env`) | _(resolved from `--env`)_ |
| `--deploy-sa-subject` | Kubernetes service-account subject for the EKS credential | `system:serviceaccount:ent-home:ent-home-api` |

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
