output "application_client_id" {
  value       = azuread_application.ent.client_id
  description = "The client (application) ID of the Ent service principal"
}

output "service_principal_object_id" {
  value       = azuread_service_principal.ent.object_id
  description = "The object ID of the Ent service principal"
}

output "role_definition_id" {
  value       = azurerm_role_definition.ent_deploy.role_definition_resource_id
  description = "The ID of the custom role definition"
}

output "role_definition_name" {
  value       = azurerm_role_definition.ent_deploy.name
  description = "The name of the custom role definition"
}

output "tenant_id" {
  value       = data.azuread_client_config.current.tenant_id
  description = "The Azure AD tenant ID"
}

output "subscription_id" {
  value       = data.azurerm_subscription.current.subscription_id
  description = "The Azure subscription ID"
}
