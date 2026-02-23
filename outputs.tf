# ============================================================================
# Landscape HA Deployment - Outputs
# ============================================================================
#
# Description: Output values for Landscape HA deployment.
#              Includes deployment info and landscape-client configuration.
#
# Author:      Marcelo Marcal <marcelo.marcal@canonical.com>
#
# ============================================================================

# ----------------------------------------------------------------------------
# Deployment Information
# ----------------------------------------------------------------------------

output "model_name" {
  description = "Juju model name (use with: juju status -m <model>)"
  value       = juju_model.landscape.name
}

output "haproxy_hostname" {
  description = "HAProxy leader unit hostname"
  value       = data.external.haproxy_hostname.result.hostname
}

# ----------------------------------------------------------------------------
# Landscape Client Configuration
# ----------------------------------------------------------------------------
# These outputs map directly to landscape-client charm config options.
# Reference: https://charmhub.io/landscape-client/configurations
#
# Usage:
#   tofu output                      # Show all outputs
#   tofu output -raw registration_key # Show sensitive values

output "landscape_client_config" {
  description = "Configuration values for landscape-client charm"
  value = {
    url            = "https://${data.external.haproxy_hostname.result.hostname}/message-system"
    ping_url       = "http://${data.external.haproxy_hostname.result.hostname}/ping"
    ssl_public_key = abspath("${var.ssl_cert_export_path}/landscape.crt")
    account_name   = "standalone"
  }
}

output "registration_key" {
  description = "Client enrollment key (landscape-client: registration-key)"
  value       = local.landscape_registration_key
  sensitive   = true
}
