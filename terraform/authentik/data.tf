# =============================================================
# Kubernetes secrets — existing client credentials in cluster
# =============================================================

data "kubernetes_secret_v1" "flux_web_client" {
  metadata {
    name      = "flux-web-client"
    namespace = "flux-system"
  }
}

data "kubernetes_secret_v1" "kagent_oauth2_proxy" {
  metadata {
    name      = "kagent-oauth2-proxy"
    namespace = "kagent"
  }
}

data "kubernetes_secret_v1" "grafana_oauth" {
  metadata {
    name      = "auth-generic-oauth-secret"
    namespace = "monitoring"
  }
}

data "kubernetes_secret_v1" "kiali_oidc" {
  metadata {
    name      = "kiali"
    namespace = "istio-system"
  }
}

# =============================================================
# Authentik — flows and signing certificate
# =============================================================

data "authentik_flow" "authorization" {
  slug = "default-provider-authorization-implicit-consent"
}

data "authentik_flow" "invalidation" {
  slug = "default-invalidation-flow"
}

data "authentik_certificate_key_pair" "default" {
  name = "authentik Self-signed Certificate"
}

# =============================================================
# Authentik — default OAuth2 scope mappings
# =============================================================

data "authentik_property_mapping_provider_scope" "oauth2" {
  managed_list = [
    "goauthentik.io/providers/oauth2/scope-openid",
    "goauthentik.io/providers/oauth2/scope-profile",
    "goauthentik.io/providers/oauth2/scope-offline_access",
  ]
}
