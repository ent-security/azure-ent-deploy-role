variable "ent_azure_app_object_id" {
  type        = string
  description = "Object ID of the Ent Home Azure AD application (provided by Ent)"

  validation {
    condition     = can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.ent_azure_app_object_id))
    error_message = "ent_azure_app_object_id must be a valid UUID."
  }
}

variable "subscription_id" {
  type        = string
  description = "Azure subscription ID where Ent will deploy infrastructure"

  validation {
    condition     = can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.subscription_id))
    error_message = "subscription_id must be a valid UUID."
  }
}

variable "role_name" {
  type        = string
  default     = "Ent Home Deploy Role"
  description = "Display name for the custom Azure role definition"
}

variable "role_description" {
  type        = string
  default     = "Custom role that grants Ent Home permissions to deploy and manage infrastructure in this subscription"
  description = "Description for the custom Azure role definition"
}

variable "service_principal_name" {
  type        = string
  default     = "ent-home-deploy"
  description = "Display name for the service principal"
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "A map of tags to add to resources that support tagging"
}
