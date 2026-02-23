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
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
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

  # Read registration key from file if it exists, otherwise use variable
  landscape_registration_key = (
    fileexists(var.landscape_registration_key_file)
    ? trimspace(file(var.landscape_registration_key_file))
    : var.landscape_registration_key
  )

  # Build admin config from variables, excluding empty values
  landscape_admin_config = {
    for k, v in {
      "admin_email"      = var.landscape_admin_email
      "admin_name"       = var.landscape_admin_name
      "admin_password"   = local.landscape_admin_password
      "registration_key" = local.landscape_registration_key
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
  config = merge(var.haproxy.config, {
    "ssl_cert" = base64encode(tls_locally_signed_cert.haproxy.cert_pem)
    "ssl_key"  = base64encode(tls_private_key.haproxy.private_key_pem)
  })
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
# SSL/TLS CERTIFICATE
# ============================================================================
# Creates a local CA and signs a server certificate for HAProxy.
# The CA cert is exported for Landscape clients (ssl-public-key).
# The server cert + key are injected into HAProxy for TLS termination.

# ----------------------------------------------------------------------------
# Certificate Authority
# ----------------------------------------------------------------------------
resource "tls_private_key" "ca" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "ca" {
  private_key_pem = tls_private_key.ca.private_key_pem

  subject {
    common_name = "${var.ssl_cert_cn} CA"
  }

  validity_period_hours = 87600 # 10 years
  is_ca_certificate     = true

  allowed_uses = [
    "cert_signing",
    "crl_signing",
  ]
}

# ----------------------------------------------------------------------------
# Server Certificate (signed by CA)
# ----------------------------------------------------------------------------
resource "tls_private_key" "haproxy" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "haproxy" {
  private_key_pem = tls_private_key.haproxy.private_key_pem

  subject {
    common_name = var.ssl_cert_cn
  }

  dns_names = var.ssl_cert_sans
}

resource "tls_locally_signed_cert" "haproxy" {
  cert_request_pem   = tls_cert_request.haproxy.cert_request_pem
  ca_private_key_pem = tls_private_key.ca.private_key_pem
  ca_cert_pem        = tls_self_signed_cert.ca.cert_pem

  validity_period_hours = 87600 # 10 years

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

# ----------------------------------------------------------------------------
# Export CA Certificate
# ----------------------------------------------------------------------------
# Writes the CA certificate to the configured export path for use
# by Landscape clients (landscape-client ssl-public-key config).
resource "local_file" "landscape_cert" {
  content  = tls_self_signed_cert.ca.cert_pem
  filename = "${var.ssl_cert_export_path}/landscape.crt"
}
