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
  default     = "Ent Platform Deploy Role"
  description = "Display name for the custom Azure role definition"
}

variable "role_description" {
  type        = string
  default     = "Custom role that grants Ent permissions to deploy and manage infrastructure in this subscription"
  description = "Description for the custom Azure role definition"
}

variable "service_principal_name" {
  type        = string
  default     = "ent-platform-deploy"
  description = "Display name for the service principal and app registration"
}

variable "github_repository" {
  type        = string
  default     = "ent-security/ent-platform"
  description = "GitHub repository in owner/repo format for OIDC federation"
}

variable "github_ref" {
  type        = string
  default     = "refs/heads/main"
  description = "Git ref for the federated identity credential (e.g., refs/heads/main)"
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags to add to resources that support tagging"
}
