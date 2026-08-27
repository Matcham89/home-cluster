# =============================================================
# Look up existing Authentik users by username.
# Add a new data block for each user you want to manage in groups.
# =============================================================

data "authentik_user" "service_account" {
  username = "terraform_kubegit_service_account"
}

# =============================================================
# Look up the built-in "authentik Admins" superuser group. Not managed as
# a resource here (pre-existing, has other members like akadmin) — just
# referenced so matcham89 can be added to it without touching who else
# is in it. The 3 groups below (flux-admins, Grafana Admins/Editors) ARE
# managed as resources in groups.tf, so matcham89's membership in those
# is added there instead (on the group's `users` list) — don't also set
# their ids here, or the two resources will fight over the same M2M edge.
# =============================================================

data "authentik_group" "authentik_admins" {
  name = "authentik Admins"
}

# =============================================================
# matcham89 — personal admin user.
# No email set here on purpose (avoid committing a personal email address
# to git) — set it later via Directory -> Users -> matcham89 in the UI if
# an app needs it (e.g. Grafana's OIDC email-claim-based user matching).
# No password set either — use the recovery-key flow in the README to set
# one after this is applied.
# =============================================================

resource "authentik_user" "matcham89" {
  username = "matcham89"
  name     = "matcham89"
  groups   = [data.authentik_group.authentik_admins.id]
}
