# =============================================================
# Look up existing Authentik users by username.
# Add a new data block for each user you want to manage in groups.
# =============================================================

data "authentik_user" "matcham89" {
  username = "matcham89"
}
