# ============================================================================
# Landscape HA Deployment on MAAS
# ============================================================================
#
# Description: Deploys Canonical Landscape Server in High Availability mode
#              on bare metal machines managed by MAAS using Juju.
#
# Author:      Marcelo Marcal <marcelo.marcal@canonical.com>
# Repository:  https://github.com/msmarcal/landscape-ha
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

locals {
  # Inject SSH public key into all machines via Juju authorized-keys
  ssh_authorized_keys = (
    fileexists(pathexpand(var.ssh_public_key_file))
    ? { "authorized-keys" = trimspace(file(pathexpand(var.ssh_public_key_file))) }
    : {}
  )
}

resource "juju_model" "landscape" {
  name = var.model_name

  cloud {
    name   = var.cloud_name
    region = var.cloud_region
  }

  config = merge(var.model_config, local.ssh_authorized_keys)
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
# POST-DEPLOYMENT
# ============================================================================

# ----------------------------------------------------------------------------
# Export HAProxy SSL Certificate
# ----------------------------------------------------------------------------
# Extracts the self-signed certificate from HAProxy for use by Landscape
# clients. The certificate is saved to the specified path for distribution.
# Requires ssl_cert = "SELFSIGNED" in the HAProxy charm config.
resource "null_resource" "export_haproxy_cert" {
  depends_on = [
    juju_integration.landscape_haproxy
  ]

  triggers = {
    # Re-run if haproxy application changes
    haproxy_app = juju_application.haproxy.name
  }

  provisioner "local-exec" {
    command = <<-EOT
      echo "Waiting for HAProxy to generate self-signed certificate..."
      MAX_ATTEMPTS=30
      ATTEMPT=0
      while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
        ATTEMPT=$((ATTEMPT + 1))
        if juju exec --unit ${var.haproxy.app_name}/0 -- \
          'test -s /var/lib/haproxy/default.pem' 2>/dev/null; then
          echo "Certificate found after $ATTEMPT attempt(s)."
          break
        fi
        echo "Attempt $ATTEMPT/$MAX_ATTEMPTS: certificate not ready, retrying in 10s..."
        sleep 10
      done

      if [ $ATTEMPT -eq $MAX_ATTEMPTS ]; then
        echo "ERROR: Certificate was not generated after $MAX_ATTEMPTS attempts." >&2
        exit 1
      fi

      echo "Exporting HAProxy SSL certificate..."
      mkdir -p "${var.ssl_cert_export_path}"
      juju exec --unit ${var.haproxy.app_name}/0 -- \
        'openssl x509 -in /var/lib/haproxy/default.pem' \
        > "${var.ssl_cert_export_path}/landscape.crt"
      echo "Certificate exported to ${var.ssl_cert_export_path}/landscape.crt"
    EOT
  }
}
