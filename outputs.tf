output "model_name" {
  description = "Name of the Juju model"
  value       = juju_model.landscape.name
}

output "landscape_url" {
  description = "URL to access Landscape (via HAProxy)"
  value       = "https://${var.ssl_cert_cn}/"
}

output "ssl_cert_path" {
  description = "Path to exported SSL certificate"
  value       = "${var.ssl_cert_export_path}/landscape.crt"
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
