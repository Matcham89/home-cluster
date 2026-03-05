resource "authentik_group" "flux_admins" {
  name  = "flux-admins"
  users = [data.authentik_user.matcham89.id]
}

resource "authentik_group" "grafana_admins" {
  name  = "Grafana Admins"
  users = [data.authentik_user.matcham89.id]
}

resource "authentik_group" "grafana_editors" {
  name  = "Grafana Editors"
  users = []
}
