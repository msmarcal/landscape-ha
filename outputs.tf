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
  description = "Name of the Juju model"
  value       = juju_model.landscape.name
}

output "landscape_server" {
  description = "Landscape Server application name"
  value       = juju_application.landscape_server.name
}

output "postgresql" {
  description = "PostgreSQL application name"
  value       = juju_application.postgresql.name
}

output "haproxy" {
  description = "HAProxy application name"
  value       = juju_application.haproxy.name
}

output "rabbitmq_server" {
  description = "RabbitMQ Server application name"
  value       = juju_application.rabbitmq_server.name
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

output "landscape_url" {
  description = "Message server URL (landscape-client: url)"
  value       = "https://${data.external.haproxy_hostname.result.hostname}/message-system"
}

output "landscape_ping_url" {
  description = "Ping server URL (landscape-client: ping-url)"
  value       = "http://${data.external.haproxy_hostname.result.hostname}/ping"
}

output "ssl_cert_path" {
  description = "Path to exported SSL certificate (landscape-client: ssl-public-key)"
  value       = "${var.ssl_cert_export_path}/landscape.crt"
}

output "registration_key" {
  description = "Client enrollment key (landscape-client: registration-key)"
  value       = local.landscape_registration_key
  sensitive   = true
}

output "account_name" {
  description = "Landscape account name (landscape-client: account-name)"
  value       = "standalone"
}
