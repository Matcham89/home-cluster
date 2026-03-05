variable "authentik_url" {
  description = "Base URL of the Authentik instance."
  type        = string
  default     = "https://authentik.kubegit.com"
}

variable "authentik_token" {
  description = "Authentik API token. Set via TF_VAR_authentik_token environment variable."
  type        = string
  sensitive   = true
}

variable "kube_context" {
  description = "Kubernetes context for reading cluster secrets. Leave empty to use the current context."
  type        = string
  default     = ""
}
