# Org-level read-only role bindings for boris-reader. Org-level (not project)
# so newly created projects are covered automatically by IAM inheritance.
#
# google_organization_iam_member is non-authoritative (adds only this binding,
# leaves other members intact) — safe on a shared org policy.

resource "google_organization_iam_member" "boris_reader" {
  for_each = toset(local.org_roles)

  org_id = var.organization_id
  role   = each.value
  member = "serviceAccount:${google_service_account.boris_reader.email}"

  # Grant read access only after the guardrail exists. Without this, Terraform
  # creates the bindings and the deny policy concurrently, leaving a window where
  # boris-reader holds org-wide read with nothing blocking sensitive data-plane
  # reads. It closes the mirror-image window on destroy too: the bindings are
  # removed before the deny policy, rather than after it. No-op when
  # enable_deny_policy = false, since the resource then has zero instances.
  depends_on = [google_iam_deny_policy.sensitive_data]
}
