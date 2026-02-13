# ============================================================================
# Landscape HA Deployment on MAAS
# ============================================================================
#
# Description: Deploys Canonical Landscape Server in High Availability mode
#              on bare metal machines managed by MAAS using Juju.
#
# Author:      Marcelo Marcal <marcelo.marcal@canonical.com>
# Repository:  https://github.com/canonical/landscape-deploy
#
# Architecture:
#   - Landscape Server (3 units) - Stateless application servers
#   - PostgreSQL (3 units)       - Database with Patroni HA
#   - RabbitMQ (3 units)         - Message queue cluster
#   - HAProxy (1 unit)           - TLS termination and load balancing
#
# Prerequisites:
#   - MAAS cloud with available machines tagged appropriately
#   - Juju controller bootstrapped on MAAS
#   - Machines tagged: landscape, landscapesql, landscapeamqp, landscapeha
#
# ============================================================================

terraform {
  required_version = ">= 1.10"

  required_providers {
    juju = {
      source  = "juju/juju"
      version = "~> 0.14"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

# ----------------------------------------------------------------------------
# Provider Configuration
# ----------------------------------------------------------------------------
# Uses existing Juju client configuration from ~/.local/share/juju/
# Ensure you have switched to the correct controller before running:
#   juju switch <controller-name>
provider "juju" {}

# ----------------------------------------------------------------------------
# Juju Model
# ----------------------------------------------------------------------------
# Creates a dedicated model for Landscape deployment on the MAAS cloud.
# All applications and integrations are deployed within this model.
resource "juju_model" "landscape" {
  name = var.model_name

  cloud {
    name   = var.cloud_name
    region = var.cloud_region
  }

  config = var.model_config
}

# ============================================================================
# APPLICATION DEPLOYMENTS
# ============================================================================

# ----------------------------------------------------------------------------
# Landscape Server
# ----------------------------------------------------------------------------
# Canonical's systems management solution for Ubuntu.
# Deployed as stateless units behind HAProxy for load balancing.
# Requires PostgreSQL for data persistence and RabbitMQ for async messaging.

locals {
  # Read password from file if it exists, otherwise use variable
  landscape_admin_password = (
    fileexists(var.landscape_admin_password_file)
    ? trimspace(file(var.landscape_admin_password_file))
    : var.landscape_admin_password
  )

  # Build admin config from variables, excluding empty values
  landscape_admin_config = {
    for k, v in {
      "admin_email"    = var.landscape_admin_email
      "admin_name"     = var.landscape_admin_name
      "admin_password" = local.landscape_admin_password
    } : k => v if v != ""
  }

  # Merge admin config with user-provided config (user config takes precedence)
  landscape_config = merge(local.landscape_admin_config, var.landscape_server.config)
}

resource "juju_application" "landscape_server" {
  name  = var.landscape_server.app_name
  model = juju_model.landscape.name

  charm {
    name     = "landscape-server"
    channel  = var.landscape_server.channel
    revision = var.landscape_server.revision
    base     = var.landscape_server.base
  }

  units       = var.landscape_server.units
  constraints = var.landscape_server.constraints
  config      = local.landscape_config
}

# ----------------------------------------------------------------------------
# PostgreSQL
# ----------------------------------------------------------------------------
# Primary database for Landscape. Uses Charmed PostgreSQL with Patroni
# for automatic failover and streaming replication between units.
# Required plugins: plpython3u, ltree, intarray, debversion, pg_trgm
resource "juju_application" "postgresql" {
  name  = var.postgresql.app_name
  model = juju_model.landscape.name

  charm {
    name     = "postgresql"
    channel  = var.postgresql.channel
    revision = var.postgresql.revision
    base     = var.postgresql.base
  }

  units       = var.postgresql.units
  constraints = var.postgresql.constraints
  config      = var.postgresql.config
}

# ----------------------------------------------------------------------------
# HAProxy
# ----------------------------------------------------------------------------
# Load balancer and TLS termination point for Landscape Server.
# Provides a single entry point for all client connections.
# Handles SSL/TLS certificates and distributes traffic across Landscape units.
resource "juju_application" "haproxy" {
  name  = var.haproxy.app_name
  model = juju_model.landscape.name

  charm {
    name     = "haproxy"
    channel  = var.haproxy.channel
    revision = var.haproxy.revision
    base     = var.haproxy.base
  }

  units       = var.haproxy.units
  constraints = var.haproxy.constraints
  config      = var.haproxy.config
}

# ----------------------------------------------------------------------------
# RabbitMQ
# ----------------------------------------------------------------------------
# Message broker for asynchronous task processing in Landscape.
# Deployed as a cluster with mirrored queues for high availability.
# Handles background jobs like package updates, script execution, etc.
resource "juju_application" "rabbitmq_server" {
  name  = var.rabbitmq_server.app_name
  model = juju_model.landscape.name

  charm {
    name     = "rabbitmq-server"
    channel  = var.rabbitmq_server.channel
    revision = var.rabbitmq_server.revision
    base     = var.rabbitmq_server.base
  }

  units       = var.rabbitmq_server.units
  constraints = var.rabbitmq_server.constraints
  config      = var.rabbitmq_server.config
}

# ============================================================================
# INTEGRATIONS (Relations)
# ============================================================================

# ----------------------------------------------------------------------------
# Landscape <-> RabbitMQ (AMQP)
# ----------------------------------------------------------------------------
# Provides message queue connectivity for async job processing.
# Landscape submits tasks to RabbitMQ; workers consume and execute them.
resource "juju_integration" "landscape_rabbitmq" {
  model = juju_model.landscape.name

  application {
    name = juju_application.landscape_server.name
  }

  application {
    name = juju_application.rabbitmq_server.name
  }
}

# ----------------------------------------------------------------------------
# Landscape <-> HAProxy (HTTP)
# ----------------------------------------------------------------------------
# Registers Landscape Server backends with HAProxy.
# HAProxy automatically updates its configuration when units are added/removed.
resource "juju_integration" "landscape_haproxy" {
  model = juju_model.landscape.name

  application {
    name = juju_application.landscape_server.name
  }

  application {
    name = juju_application.haproxy.name
  }
}

# ----------------------------------------------------------------------------
# Landscape <-> PostgreSQL (Database)
# ----------------------------------------------------------------------------
# Provides database connectivity using the db-admin endpoint.
# Landscape requires admin privileges for schema management and migrations.
resource "juju_integration" "landscape_postgresql" {
  model = juju_model.landscape.name

  application {
    name     = juju_application.landscape_server.name
    endpoint = "db"
  }

  application {
    name     = juju_application.postgresql.name
    endpoint = "db-admin"
  }
}

# ============================================================================
# POST-DEPLOYMENT WORKAROUNDS
# ============================================================================
# The HAProxy charm (latest/stable) has a bug on Ubuntu 22.04/24.04 where
# self-signed certificate generation fails silently.
#
# NOTE: Duplicate frontend blocks are prevented by setting services="" in
#       the HAProxy charm config.

# ----------------------------------------------------------------------------
# HAProxy SSL Certificate Generation
# ----------------------------------------------------------------------------
# Workaround for HAProxy charm SSL bug:
#   - Generates self-signed SSL certificate manually with SANs
#   - Restarts HAProxy service to load the certificate
resource "null_resource" "haproxy_ssl_cert" {
  depends_on = [
    juju_integration.landscape_haproxy
  ]

  triggers = {
    # Re-run if haproxy application changes
    haproxy_app = juju_application.haproxy.name
  }

  provisioner "local-exec" {
    command = <<-EOT
      echo "Waiting for HAProxy deployment to stabilize..."
      sleep 60

      echo "Generating self-signed SSL certificate with SANs..."
      HAPROXY_IP=$(juju status ${var.haproxy.app_name}/0 --format json | jq -r '.applications["${var.haproxy.app_name}"].units["${var.haproxy.app_name}/0"]["public-address"]')

      # Build SAN list from variable + discovered IP
      SAN_LIST="IP:$HAPROXY_IP"
      %{ for san in var.ssl_cert_sans ~}
      SAN_LIST="$SAN_LIST,DNS:${san}"
      %{ endfor ~}

      juju exec --unit ${var.haproxy.app_name}/0 -- "openssl req -x509 -nodes \
        -newkey rsa:2048 \
        -keyout /var/lib/haproxy/default.pem \
        -out /tmp/cert.pem \
        -days 365 \
        -subj '/CN=${var.ssl_cert_cn}' \
        -addext 'subjectAltName=$SAN_LIST' 2>&1 && \
        cat /tmp/cert.pem >> /var/lib/haproxy/default.pem && \
        chown haproxy:haproxy /var/lib/haproxy/default.pem && \
        chmod 600 /var/lib/haproxy/default.pem"

      echo "Restarting HAProxy to load certificate..."
      juju exec --unit ${var.haproxy.app_name}/0 -- 'systemctl restart haproxy'

      echo "HAProxy SSL certificate generated successfully."
    EOT
  }
}

# ----------------------------------------------------------------------------
# Export HAProxy SSL Certificate
# ----------------------------------------------------------------------------
# Extracts the self-signed certificate from HAProxy for use by Landscape
# clients. The certificate is saved to the specified path for distribution.
resource "null_resource" "export_haproxy_cert" {
  depends_on = [
    null_resource.haproxy_ssl_cert
  ]

  triggers = {
    # Re-run if haproxy application changes
    haproxy_app = juju_application.haproxy.name
  }

  provisioner "local-exec" {
    command = <<-EOT
      echo "Exporting HAProxy SSL certificate..."
      mkdir -p "${var.ssl_cert_export_path}"
      juju exec --unit ${var.haproxy.app_name}/0 -- \
        'openssl x509 -in /var/lib/haproxy/default.pem 2>/dev/null' \
        > "${var.ssl_cert_export_path}/landscape.crt"
      echo "Certificate exported to ${var.ssl_cert_export_path}/landscape.crt"
    EOT
  }
}
