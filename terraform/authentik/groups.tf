resource "authentik_group" "flux_admins" {
  name  = "flux-admins"
  users = [data.authentik_user.service_account.id, authentik_user.matcham89.id]
}

resource "authentik_group" "grafana_admins" {
  name  = "Grafana Admins"
  users = [data.authentik_user.service_account.id, authentik_user.matcham89.id]
}

resource "authentik_group" "grafana_editors" {
  name  = "Grafana Editors"
  users = [authentik_user.matcham89.id]
}

resource "authentik_group" "cc_flux_viewer" {
  name  = "cc-flux-viewer"
  users = [authentik_user.matcham89.id]
}

resource "authentik_group" "cc_flux_admin" {
  name  = "cc-flux-admin"
  users = [authentik_user.matcham89.id]
}
