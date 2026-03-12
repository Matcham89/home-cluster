terraform {
  required_version = ">= 1.5"

  required_providers {
    authentik = {
      source  = "goauthentik/authentik"
      version = "~> 2025.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
  }
}

provider "authentik" {
  url   = var.authentik_url
  token = var.authentik_token
}

provider "kubernetes" {
  config_path    = "~/.kube/config"
  config_context = var.kube_context != "" ? var.kube_context : null
}
