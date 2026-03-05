# =============================================================
# Custom scope mapping — groups claim
# Authentik doesn't ship a managed "groups" scope, so we create one.
# This includes the user's group names in the token under the "groups" key.
# =============================================================

# email_verified must be True so Grafana v11 uses email-based user lookup.
# Without it, Grafana skips the email lookup and fails to match the existing user.
resource "authentik_property_mapping_provider_scope" "email" {
  name       = "OAuth Mapping: Email"
  scope_name = "email"
  expression = "return {\"email\": request.user.email, \"email_verified\": True}"
}

resource "authentik_property_mapping_provider_scope" "groups" {
  name       = "OAuth Mapping: Groups"
  scope_name = "profile"
  expression = "return {\"groups\": [group.name for group in request.user.ak_groups.all()]}"
}

# =============================================================
# Flux Web UI
# Provider slug: flux-kubegit-com
# Client credentials: k8s secret flux-system/flux-web-client
# =============================================================

resource "authentik_provider_oauth2" "flux" {
  name          = "Flux Web UI"
  client_id     = data.kubernetes_secret_v1.flux_web_client.data["client-id"]
  client_secret = data.kubernetes_secret_v1.flux_web_client.data["client-secret"]

  authorization_flow = data.authentik_flow.authorization.id
  invalidation_flow  = data.authentik_flow.invalidation.id
  signing_key        = data.authentik_certificate_key_pair.default.id
  property_mappings  = concat(data.authentik_property_mapping_provider_scope.oauth2.ids, [authentik_property_mapping_provider_scope.email.id, authentik_property_mapping_provider_scope.groups.id])

  allowed_redirect_uris = [
    {
      matching_mode = "strict"
      url           = "https://flux.kubegit.com/oauth2/callback"
    }
  ]

  sub_mode               = "hashed_user_id"
  access_token_validity  = "hours=1"
  refresh_token_validity = "days=30"
}

resource "authentik_application" "flux" {
  name              = "Flux"
  slug              = "flux-kubegit-com"
  protocol_provider = authentik_provider_oauth2.flux.id
  meta_launch_url   = "https://flux.kubegit.com"
  open_in_new_tab   = true
}

# =============================================================
# Kagent
# Provider slug: kagent-kubegit-com
# Client credentials: k8s secret kagent/kagent-oauth2-proxy
# =============================================================

resource "authentik_provider_oauth2" "kagent" {
  name          = "Kagent"
  client_id     = data.kubernetes_secret_v1.kagent_oauth2_proxy.data["client-id"]
  client_secret = data.kubernetes_secret_v1.kagent_oauth2_proxy.data["client-secret"]

  authorization_flow = data.authentik_flow.authorization.id
  invalidation_flow  = data.authentik_flow.invalidation.id
  signing_key        = data.authentik_certificate_key_pair.default.id
  property_mappings  = concat(data.authentik_property_mapping_provider_scope.oauth2.ids, [authentik_property_mapping_provider_scope.email.id, authentik_property_mapping_provider_scope.groups.id])

  allowed_redirect_uris = [
    {
      matching_mode = "strict"
      url           = "https://kagent.kubegit.com/oauth2/callback"
    }
  ]

  sub_mode               = "hashed_user_id"
  access_token_validity  = "hours=1"
  refresh_token_validity = "days=30"
}

resource "authentik_application" "kagent" {
  name              = "Kagent"
  slug              = "kagent-kubegit-com"
  protocol_provider = authentik_provider_oauth2.kagent.id
  meta_launch_url   = "https://kagent.kubegit.com"
  open_in_new_tab   = true
}

# =============================================================
# Grafana
# Provider slug: grafana-kubegit-com
# Client credentials: k8s secret monitoring/auth-generic-oauth-secret
# Role mapping via groups: "Grafana Admins" → Admin, "Grafana Editors" → Editor
# =============================================================

resource "authentik_provider_oauth2" "grafana" {
  name          = "Grafana"
  client_id     = data.kubernetes_secret_v1.grafana_oauth.data["client_id"]
  client_secret = data.kubernetes_secret_v1.grafana_oauth.data["client_secret"]

  authorization_flow = data.authentik_flow.authorization.id
  invalidation_flow  = data.authentik_flow.invalidation.id
  signing_key        = data.authentik_certificate_key_pair.default.id
  property_mappings  = concat(data.authentik_property_mapping_provider_scope.oauth2.ids, [authentik_property_mapping_provider_scope.email.id, authentik_property_mapping_provider_scope.groups.id])

  allowed_redirect_uris = [
    {
      matching_mode = "strict"
      url           = "https://grafana.kubegit.com/login/generic_oauth"
    }
  ]

  sub_mode               = "hashed_user_id"
  access_token_validity  = "hours=1"
  refresh_token_validity = "days=30"
}

resource "authentik_application" "grafana" {
  name              = "Grafana"
  slug              = "grafana-kubegit-com"
  protocol_provider = authentik_provider_oauth2.grafana.id
  meta_launch_url   = "https://grafana.kubegit.com"
  open_in_new_tab   = true
}

# =============================================================
# Kiali
# Provider slug: kiali-kubegit-com
# Client ID sourced from kiali CR (istio-system/kiali.yaml)
# Client secret: k8s secret istio-system/kiali (key: oidc-secret)
# =============================================================

resource "authentik_provider_oauth2" "kiali" {
  name = "Kiali"
  # client_id is hardcoded in the Kiali CR (istio-system/kiali.yaml).
  # If you rotate it, update both here and in the Kiali CR.
  client_id     = "B86FR4ySUv3u41K25pbnb9vCCbT4Z0RSLQP1xGw1"
  client_secret = data.kubernetes_secret_v1.kiali_oidc.data["oidc-secret"]

  authorization_flow = data.authentik_flow.authorization.id
  invalidation_flow  = data.authentik_flow.invalidation.id
  signing_key        = data.authentik_certificate_key_pair.default.id
  property_mappings  = concat(data.authentik_property_mapping_provider_scope.oauth2.ids, [authentik_property_mapping_provider_scope.email.id, authentik_property_mapping_provider_scope.groups.id])

  allowed_redirect_uris = [
    {
      matching_mode = "strict"
      url = "https://kiali.kubegit.com"
    }
  ]

  sub_mode               = "hashed_user_id"
  access_token_validity  = "hours=1"
  refresh_token_validity = "days=30"
}

resource "authentik_application" "kiali" {
  name              = "Kiali"
  slug              = "kiali-kubegit-com"
  protocol_provider = authentik_provider_oauth2.kiali.id
  meta_launch_url   = "https://kiali.kubegit.com"
  open_in_new_tab   = true
}
