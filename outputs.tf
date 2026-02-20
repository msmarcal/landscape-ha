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
# These outputs provide the values needed to configure the landscape-client
# charm (https://charmhub.io/landscape-client/configurations).

output "landscape_url" {
  description = "Landscape message server URL (landscape-client 'url' config)"
  value       = "https://${data.external.haproxy_hostname.result.hostname}/message-system"
}

output "landscape_ping_url" {
  description = "Landscape ping server URL (landscape-client 'ping-url' config)"
  value       = "http://${data.external.haproxy_hostname.result.hostname}/ping"
}

output "ssl_cert_path" {
  description = "Path to exported SSL certificate (landscape-client 'ssl-public-key' config)"
  value       = "${var.ssl_cert_export_path}/landscape.crt"
}

output "registration_key" {
  description = "Registration key for client enrollment (landscape-client 'registration-key' config)"
  value       = local.landscape_registration_key
  sensitive   = true
}

output "account_name" {
  description = "Landscape account name (landscape-client 'account-name' config)"
  value       = "standalone"
}
