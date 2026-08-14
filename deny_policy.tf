# Org-level IAM deny policy blocking sensitive data-plane reads for boris-reader.
# Required by default; disable with enable_deny_policy = false.
#
# Applying this requires roles/iam.denyAdmin at the org level. The deny targets
# only the boris-reader principal, so it never affects other org identities.

resource "google_iam_deny_policy" "sensitive_data" {
  count = var.enable_deny_policy ? 1 : 0

  # Attachment point is the URL-encoded full resource name of the org.
  # The name carries a customer-derived suffix (see local.deny_policy_id) because
  # deny-policy IDs are unique per attachment point and the attachment point is
  # the shared org.
  parent       = "cloudresourcemanager.googleapis.com%2Forganizations%2F${var.organization_id}"
  name         = local.deny_policy_id
  display_name = "B.O.R.I.S Sensitive Data Guardrail"

  rules {
    deny_rule {
      denied_principals  = ["principal://iam.googleapis.com/projects/-/serviceAccounts/${google_service_account.boris_reader.email}"]
      denied_permissions = local.denied_permissions
    }
  }
}
