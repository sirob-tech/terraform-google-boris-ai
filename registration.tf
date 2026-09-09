# Optional self-registration, so onboarding completes in a single apply.
#
# When enable_self_registration is true, the module PUTs to the B.O.R.I.S
# registration endpoint AFTER all resources exist. Deliberately a create-time
# action via terraform_data + local-exec, NOT the `http` data source (data
# sources re-run on every plan/refresh; registration must run once on create).
#
# The endpoint is idempotent for the organization this secret is bound to:
# re-sending the same organization succeeds even when project_number,
# service_account_email or hosting_project_id have changed, which is how a
# corrected value re-applies without an operator. The trigger below re-fires the
# PUT only when a registered value changes, so an unchanged re-apply does not
# call the endpoint again.
#
# The 409 is per SECRET, not per customer. A secret binds to the first
# organization it registers and cannot be moved, so pointing this module's
# secret at a different organization is refused. Registering a SECOND
# organization is supported and expected — one customer may hold several
# organizations, each with its own secret and its own instance of this module.
# One customer_id stays one data boundary across all of them.
#
# There is no DELETE endpoint to call, so terraform destroy could not offboard
# on its own even if it tried. Removing one organization is an operator flow:
# confirm no other live connection holds it, revoke that connection, then delete
# the published /boris/gcp/orgs/<organization_id> parameter with operator
# credentials. Destroying this module removes every customer-side grant, which
# is the half a customer can do unaided.

resource "terraform_data" "register" {
  count = var.enable_self_registration ? 1 : 0

  # customer_id is deliberately absent: identity comes from the credential rather
  # than the request, so it is not a registered value. It does key the derived
  # project ID and deny policy ID in locals.tf, and changing it replaces those
  # resources anyway — this trigger does not need to restate that.
  #
  # connection_secret is absent for a different reason: triggers_replace is
  # persisted to state, and the secret must not be. Rotating a secret is also
  # not a reason to re-register — it binds on first use and the binding survives.
  triggers_replace = {
    endpoint        = local.registration_endpoint
    organization_id = var.organization_id
    project_number  = local.hosting_project_number
    sa_email        = google_service_account.boris_reader.email

    # Every value in registration_body belongs here. hosting_project_id can
    # change without project_number changing — pointing an existing
    # registration at a different hosting project, or setting it for the first
    # time on a workspace that predates this field — and if it is not a trigger
    # that re-apply is a silent no-op: the module holds the new value, B.O.R.I.S
    # keeps the old one, and nothing reports the divergence. The endpoint
    # accepts a repeat for the same organization precisely so a corrected value
    # can be re-sent.
    hosting_project_id = local.hosting_project_id
  }

  # All interpolated values are constrained to shell-safe character sets by the
  # variable validations (organization_id / vendor account: digits;
  # service_account_id: SA-id chars; registration_endpoint: https URL chars), so
  # no shell metacharacters can reach this command. The secret is the exception
  # and is never interpolated — it arrives through the environment block below,
  # so it stays out of the command string, out of state, and out of any log of
  # the rendered command.
  #
  # --connect-timeout / --max-time keep a stalled endpoint from hanging apply.
  #
  # Anything that is not a 2xx or a 4xx is retried — 5xx, an unexpected redirect,
  # and transport failures (curl reports those as status 000) — with backoff over a
  # ~4 minute budget, enough to ride out a brief endpoint outage or a flaky network
  # path. Since each attempt can also spend its 60s --max-time, a fully stalled
  # endpoint takes ~11 minutes to give up. Registration does not exercise the WIF
  # chain, so nothing here waits on GCP IAM propagation.
  #
  # Every 4xx is terminal: a malformed identifier, a secret that was not
  # accepted, or a conflicting registration. None of those clear on their own, so
  # retrying would spend the whole backoff budget and then print advice that
  # cannot resolve the condition, and would leave automation looping against a
  # state only the B.O.R.I.S team can clear. They fail immediately with a reason.
  provisioner "local-exec" {
    environment = {
      BORIS_CONNECTION_SECRET = var.connection_secret
    }

    command = <<-EOT
      url="${local.registration_endpoint}/gcp/install/${var.organization_id}"
      body='${local.registration_body}'
      for delay in 0 15 30 30 60 60 60; do
        if [ "$delay" -gt 0 ]; then sleep "$delay"; fi

        resp=$(curl -sS -w '\n%%{http_code}' --connect-timeout 10 --max-time 60 \
          -X PUT "$url" \
          -H 'Content-Type: application/json' \
          -H "Authorization: Bearer $BORIS_CONNECTION_SECRET" \
          -d "$body") || true
        code=$(printf '%s\n' "$resp" | tail -n 1)
        message=$(printf '%s\n' "$resp" | sed '$d')

        case "$code" in
          2??)
            exit 0
            ;;
          401)
            echo "B.O.R.I.S: registration was refused: the connection secret was not accepted." >&2
            echo "B.O.R.I.S: this does not clear by retrying. Ask the B.O.R.I.S team to re-issue it." >&2
            exit 1
            ;;
          409)
            echo "B.O.R.I.S: registration was refused: $message" >&2
            echo "B.O.R.I.S: this does not clear by retrying — contact the B.O.R.I.S team." >&2
            exit 1
            ;;
          4??)
            echo "B.O.R.I.S: registration was rejected (HTTP $code): $message" >&2
            echo "B.O.R.I.S: this does not clear by retrying. Check the module inputs, then contact the B.O.R.I.S team." >&2
            exit 1
            ;;
          *)
            # The doubled $$ escapes Terraform's interpolation, leaving the shell a
            # default-value expansion. A transport failure still yields a status
            # (curl writes 000); the empty case is curl missing from PATH entirely,
            # which would otherwise print "(HTTP )".
            echo "B.O.R.I.S: registration attempt failed (HTTP $${code:-no response}); retrying" >&2
            ;;
        esac
      done
      echo "B.O.R.I.S: registration failed after retries. Verify the module applied cleanly, then re-run 'terraform apply', or register manually with the registration_curl output." >&2
      exit 1
    EOT
  }

  # Register only once the FULL access chain exists — including the deny policy,
  # so the org is never registered before the sensitive-data guardrail exists.
  # (Creation is not the same as effectiveness — IAM still has to propagate — but
  # this at least rules out registering while the guardrail is absent outright.)
  depends_on = [
    google_service_account_iam_member.wif_impersonation,
    google_organization_iam_member.boris_reader,
    google_iam_workload_identity_pool_provider.aws,
    google_iam_deny_policy.sensitive_data,
  ]
}
