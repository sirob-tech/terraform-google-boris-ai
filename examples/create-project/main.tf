# Minimal onboarding: the module creates its own hosting project for the WIF
# pool, provider, and boris-reader service account.
#
# Replace every placeholder below with your own values. customer_id and
# vendor_aws_account_id both come from your B.O.R.I.S install link.

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.41.0"
    }
  }
}

# Credentials come from your environment (gcloud ADC or impersonation). The
# module creates its own project, so no project needs to be set here.
provider "google" {}

module "boris_gcp" {
  # Published as:
  #   source  = "sirob-tech/boris-ai/google"
  #   version = "~> 1.0"
  source = "../../"

  customer_id           = "00000000-0000-0000-0000-000000000000"
  organization_id       = "123456789012"
  vendor_aws_account_id = "111122223333"

  create_project  = true
  billing_account = "XXXXXX-XXXXXX-XXXXXX"
}

# Paste this after apply to register the org with B.O.R.I.S. Prefer
# enable_self_registration if your pipeline can reach the B.O.R.I.S endpoint.
#
# Export your connection secret first — the command references it rather than
# embedding it, so that the secret never lands in Terraform state:
#
#   export BORIS_CONNECTION_SECRET='boris_...'
output "registration_curl" {
  description = "Manual registration command to run after apply. Requires BORIS_CONNECTION_SECRET in your shell."
  value       = module.boris_gcp.registration_curl
}
