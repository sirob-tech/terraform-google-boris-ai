# The three values the registration call needs, plus context.

output "organization_id" {
  description = "GCP organization ID to register with B.O.R.I.S."
  value       = var.organization_id
}

output "project_number" {
  description = "Hosting project NUMBER (used by B.O.R.I.S to construct the WIF principal)."
  value       = local.hosting_project_number
}

output "service_account_email" {
  description = "boris-reader service account email B.O.R.I.S impersonates."
  value       = google_service_account.boris_reader.email
}

output "project_id" {
  description = "Hosting project ID (created or adopted)."
  value       = local.hosting_project_id
}

output "workload_identity_pool_id" {
  description = "WIF pool ID (fixed contract string shared with the B.O.R.I.S side)."
  value       = google_iam_workload_identity_pool.boris.workload_identity_pool_id
}

output "workload_identity_provider" {
  description = "Full resource name of the AWS WIF provider."
  value       = google_iam_workload_identity_pool_provider.aws.name
}

output "mcp_custom_role" {
  description = "Full resource name of the custom role carrying mcp.tools.call, bound to boris-reader. Lets an operator confirm the live-access gate without console access."
  value       = google_project_iam_custom_role.mcp_tool_caller.name
}

# Ready-to-run manual registration command (fallback when self-registration is
# off). The customer authenticates it with the connection secret they were
# issued, which they supply from their own shell — see below.
output "registration_curl" {
  description = "Manual registration command to paste after apply (when enable_self_registration is false). Export BORIS_CONNECTION_SECRET in your shell first; the secret is deliberately not baked into this string."

  # The command carries the Authorization header but NOT the secret value: it
  # references $BORIS_CONNECTION_SECRET so the shell supplies it at paste time.
  #
  # This is not cosmetic. Outputs are persisted to state in cleartext, and
  # marking the output sensitive would only hide it from CLI display, not keep it
  # out of the state file. Splicing the real secret here would undo the care
  # taken everywhere else to keep it out of state.
  #
  # The URL carries no customer_id: the caller's identity comes from the
  # credential, so a customer record cannot be addressed by editing a path.
  value = format(
    "curl -X PUT '%s/gcp/install/%s' -H 'Content-Type: application/json' -H \"Authorization: Bearer $BORIS_CONNECTION_SECRET\" -d '%s'",
    local.registration_endpoint != "" ? local.registration_endpoint : "https://install.getboris.ai",
    var.organization_id,
    local.registration_body,
  )
}
