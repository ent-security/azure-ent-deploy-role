# azure-ent-deploy-role

Infrastructure as Code to create the Ent Security deployment role in Azure. Supports both Terraform and ARM templates.

## Terraform Usage

**Note** the example below uses `ref=main`. It is recommended to pin this module to a specific tag version (i.e. `ref=1.0.0`) to avoid breaking changes.

```hcl
module "ent_deployment_role" {
  source = "git::https://github.com/ent-security/azure-ent-deploy-role//terraform?ref=main"

  subscription_id        = "your-subscription-id"
  ent_azure_app_object_id = "provided-by-ent"
}

output "ent_client_id" {
  value = module.ent_deployment_role.application_client_id
}

output "ent_tenant_id" {
  value = module.ent_deployment_role.tenant_id
}
```

After you apply this terraform, it will output the Client ID and Tenant ID that you can paste into the Azure connection panel in Ent to initiate the connection.

### Terraform Variables

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `subscription_id` | Azure subscription ID where Ent will deploy | | Yes |
| `ent_azure_app_object_id` | Ent's Azure AD application object ID | | Yes |
| `role_name` | Custom role display name | `Ent Home Deploy Role` | No |
| `role_description` | Custom role description | (provided by module) | No |
| `service_principal_name` | Service principal display name | `ent-home-deploy` | No |
| `tags` | A map of tags to add to resources | `{}` | No |

### Terraform Outputs

| Output | Description |
|--------|-------------|
| `application_client_id` | The client ID of the Ent service principal |
| `service_principal_object_id` | The object ID of the Ent service principal |
| `role_definition_id` | The ID of the custom role definition |
| `role_definition_name` | The name of the custom role definition |
| `tenant_id` | The Azure AD tenant ID |
| `subscription_id` | The Azure subscription ID |

### Requirements

- Terraform/OpenTofu >= 1.6.0
- AzureRM Provider >= 4.0
- AzureAD Provider >= 3.0
- Permissions: `Microsoft.Authorization/roleDefinitions/write` and Azure AD Application Administrator (or equivalent)

## ARM Template Usage

Deploy using the Azure CLI (subscription-level deployment):

```bash
az deployment sub create \
  --location eastus \
  --template-file arm/template.json \
  --parameters roleName="Ent Home Deploy Role"
```

Or deploy via the Azure Portal:
1. Navigate to **Subscriptions** > your subscription > **Deployments**
2. Click **Custom deployment**
3. Upload the `arm/template.json` file
4. Fill in the parameters and deploy

> **Note**: The ARM template creates only the custom role definition. You must separately create a service principal and assign the role to it. See the Azure CLI usage section below for the full workflow.

### ARM Template Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `roleName` | Custom role display name | `Ent Home Deploy Role` |
| `roleDescription` | Custom role description | (provided by template) |

### ARM Template Outputs

| Output | Description |
|--------|-------------|
| `roleDefinitionId` | The ID of the custom role definition |
| `roleDefinitionName` | The display name of the custom role definition |

## Azure CLI Usage

Full setup using the Azure CLI:

1. Create the custom role definition:

```bash
az role definition create --role-definition '{
  "Name": "Ent Home Deploy Role",
  "Description": "Custom role for Ent Home to deploy and manage infrastructure",
  "Actions": [
    "Microsoft.Resources/subscriptions/resourceGroups/*",
    "Microsoft.Resources/deployments/*",
    "Microsoft.Network/virtualNetworks/*",
    "Microsoft.Network/networkSecurityGroups/*",
    "Microsoft.Network/natGateways/*",
    "Microsoft.Network/publicIPAddresses/*",
    "Microsoft.Network/privateEndpoints/*",
    "Microsoft.Network/privateDnsZones/*",
    "Microsoft.Network/dnszones/*",
    "Microsoft.ContainerService/managedClusters/*",
    "Microsoft.ContainerService/locations/*",
    "Microsoft.ContainerRegistry/registries/*",
    "Microsoft.ContainerRegistry/locations/*",
    "Microsoft.DBforPostgreSQL/flexibleServers/*",
    "Microsoft.DBforPostgreSQL/locations/*",
    "Microsoft.Cache/*",
    "Microsoft.KeyVault/vaults/*",
    "Microsoft.KeyVault/locations/*",
    "Microsoft.Storage/storageAccounts/*",
    "Microsoft.Storage/locations/*",
    "Microsoft.ServiceBus/namespaces/*",
    "Microsoft.ServiceBus/locations/*",
    "Microsoft.ManagedIdentity/userAssignedIdentities/*",
    "Microsoft.Authorization/roleAssignments/*",
    "Microsoft.Authorization/roleDefinitions/read",
    "Microsoft.Resources/subscriptions/providers/read",
    "Microsoft.Compute/skus/read",
    "Microsoft.Compute/locations/*",
    "Microsoft.Insights/*",
    "Microsoft.OperationalInsights/*",
    "Microsoft.Resources/tags/*"
  ],
  "NotActions": [
    "Microsoft.Authorization/roleAssignments/delete",
    "Microsoft.Authorization/roleDefinitions/write",
    "Microsoft.Authorization/roleDefinitions/delete"
  ],
  "DataActions": [
    "Microsoft.KeyVault/vaults/secrets/*",
    "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/*",
    "Microsoft.ServiceBus/namespaces/messages/*"
  ],
  "AssignableScopes": ["/subscriptions/YOUR_SUBSCRIPTION_ID"]
}'
```

2. Create a service principal:

```bash
az ad sp create-for-rbac \
  --name "ent-home-deploy" \
  --skip-assignment
```

3. Assign the custom role to the service principal:

```bash
az role assignment create \
  --assignee "SERVICE_PRINCIPAL_APP_ID" \
  --role "Ent Home Deploy Role" \
  --scope "/subscriptions/YOUR_SUBSCRIPTION_ID"
```

4. Provide the following to Ent:
   - **Tenant ID**: `az account show --query tenantId -o tsv`
   - **Client ID**: from step 2 output
   - **Subscription ID**: `az account show --query id -o tsv`

## Setup

1. Apply the Terraform module or deploy the ARM template
2. Open the Azure connection settings page in Ent
3. Enter the **Tenant ID**, **Client ID**, and **Subscription ID** from the outputs
4. Click **Save & Test Connection**

## Directory Structure

```
azure-ent-deploy-role/
├── arm/
│   └── template.json
├── terraform/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── versions.tf
├── .gitignore
└── README.md
```

## Permissions

This role grants permissions to manage the following Azure services:

| Service | Resource Provider | Scope |
|---------|-------------------|-------|
| Resource Groups | `Microsoft.Resources` | CRUD |
| Virtual Network | `Microsoft.Network` | Full (VNet, Subnet, NSG, NAT, Public IP) |
| Private Endpoints | `Microsoft.Network` | Full (Private DNS, endpoints) |
| DNS Zones | `Microsoft.Network` | Full |
| AKS | `Microsoft.ContainerService` | Full |
| Container Registry | `Microsoft.ContainerRegistry` | Full |
| PostgreSQL Flexible Server | `Microsoft.DBforPostgreSQL` | Full |
| Redis | `Microsoft.Cache` | Full |
| Key Vault | `Microsoft.KeyVault` | Full (control + data plane) |
| Storage Accounts | `Microsoft.Storage` | Full (control + data plane) |
| Service Bus | `Microsoft.ServiceBus` | Full (control + data plane) |
| Managed Identity | `Microsoft.ManagedIdentity` | Full |
| Role Assignments | `Microsoft.Authorization` | Create only (no delete) |
| Monitoring | `Microsoft.Insights` | Full |
| Log Analytics | `Microsoft.OperationalInsights` | Full |

### Excluded permissions (privilege escalation prevention)

- `Microsoft.Authorization/roleAssignments/delete`
- `Microsoft.Authorization/roleDefinitions/write`
- `Microsoft.Authorization/roleDefinitions/delete`
