# ============================================================================
# Landscape HA Deployment - Variables
# ============================================================================
#
# Description: Input variables for Landscape HA deployment on MAAS.
#              All variables have sensible defaults for a production HA setup.
#
# Author:      Marcelo Marcal <marcelo.marcal@canonical.com>
#
# Usage:
#   1. Copy terraform.tfvars.example to terraform.tfvars
#   2. Customize values for your environment
#   3. Run: tofu plan && tofu apply
#
# ============================================================================

# ----------------------------------------------------------------------------
# MAAS Cloud Configuration
# ----------------------------------------------------------------------------
# These settings define where the Juju model will be created.
# The cloud_name must match a cloud registered in your Juju client.
# Run 'juju clouds' to see available clouds.

variable "cloud_name" {
  description = "Name of the MAAS cloud in Juju (run 'juju clouds' to list)"
  type        = string
}

variable "ssl_cert_export_path" {
  description = "Path to export HAProxy's SSL certificate for Landscape clients"
  type        = string
  default     = "../../pcb-plus/secrets"
}

variable "ssl_cert_cn" {
  description = "Common Name (CN) for the self-signed SSL certificate"
  type        = string
  default     = "landscape.maas"
}

variable "ssl_cert_sans" {
  description = "Subject Alternative Names (SANs) for the SSL certificate. Include hostnames, IPs, and DNS names."
  type        = list(string)
  default     = [
    "landscape.maas",
    "landscapeha-1.maas",
    "landscapeha-2.maas",
    "landscapeha-3.maas"
  ]
}

# ----------------------------------------------------------------------------
# Landscape Admin Configuration
# ----------------------------------------------------------------------------
# Initial administrator account for Landscape. These are used during first
# deployment to create the admin user.
#
# Password is read from landscape_admin_password_file if it exists,
# otherwise falls back to landscape_admin_password variable.

variable "landscape_admin_email" {
  description = "Administrator email for Landscape"
  type        = string
  default     = ""
}

variable "landscape_admin_name" {
  description = "Administrator display name for Landscape"
  type        = string
  default     = "Administrator"
}

variable "landscape_admin_password" {
  description = "Administrator password for Landscape (sensitive). Ignored if password file exists."
  type        = string
  sensitive   = true
  default     = ""
}

variable "landscape_admin_password_file" {
  description = "Path to file containing admin password. Takes precedence over landscape_admin_password."
  type        = string
  default     = "../../pcb-plus/secrets/landscape-password.txt"
}

variable "cloud_region" {
  description = "MAAS region to deploy to (usually 'default')"
  type        = string
  default     = "default"
}

# ----------------------------------------------------------------------------
# Juju Model Configuration
# ----------------------------------------------------------------------------
# The model is a logical grouping of applications in Juju.
# All Landscape components will be deployed in this model.

variable "model_name" {
  description = "Name of the Juju model to create for Landscape"
  type        = string
  default     = "landscape"
}

variable "model_config" {
  description = "Juju model configuration options (key-value pairs)"
  type        = map(string)
  default = {
    "logging-config" = "<root>=WARNING"
  }
}

# ============================================================================
# APPLICATION CONFIGURATIONS
# ============================================================================
# Each application has the following configurable options:
#
#   app_name    - Name of the application in Juju (default: charm name)
#   channel     - Charm channel to deploy from (e.g., "latest/stable")
#   revision    - Specific charm revision (optional, overrides channel)
#   base        - Ubuntu base to deploy on (e.g., "ubuntu@24.04")
#   units       - Number of units for HA (3 recommended for most)
#   constraints - Juju constraints for machine selection (tags, zones, etc.)
#   config      - Charm-specific configuration options
#
# ============================================================================

# ----------------------------------------------------------------------------
# Landscape Server
# ----------------------------------------------------------------------------
# Canonical's systems management solution. Stateless application that
# requires PostgreSQL and RabbitMQ backends.
#
# Key config options:
#   admin_email  - Administrator email for initial setup
#   admin_name   - Administrator display name
#   root_url     - Public URL for accessing Landscape
#   license_file - Landscape license (base64 encoded)

variable "landscape_server" {
  description = "Landscape Server charm configuration"
  type = object({
    app_name    = optional(string, "landscape-server")
    channel     = optional(string, "latest/stable")
    revision    = optional(number)
    base        = optional(string, "ubuntu@24.04")
    units       = optional(number, 3)
    constraints = optional(string, "")
    config      = optional(map(string), {})
  })
  default = {}
}

# ----------------------------------------------------------------------------
# PostgreSQL
# ----------------------------------------------------------------------------
# Charmed PostgreSQL with Patroni for automatic HA failover.
#
# IMPORTANT: Use channel 14/stable with ubuntu@22.04. This version provides
#            the legacy 'pgsql' interface required by landscape-server.
#            Channel 16/stable uses the new 'postgresql_client' interface
#            which is NOT compatible with landscape-server.
#
# Required plugins for Landscape:
#   - plpython3u  : Python stored procedures
#   - ltree       : Hierarchical tree-like structures
#   - intarray    : Integer array functions
#   - debversion  : Debian package version comparison
#   - pg_trgm     : Trigram matching for text search

variable "postgresql" {
  description = "PostgreSQL charm configuration"
  type = object({
    app_name    = optional(string, "postgresql")
    channel     = optional(string, "14/stable")
    revision    = optional(number)
    base        = optional(string, "ubuntu@22.04")
    units       = optional(number, 3)
    constraints = optional(string, "")
    config      = optional(map(string), {})
  })
  default = {}
}

# ----------------------------------------------------------------------------
# HAProxy
# ----------------------------------------------------------------------------
# Load balancer providing TLS termination and traffic distribution.
# Single unit is typical; add more for load balancer redundancy.
#
# IMPORTANT: Use ubuntu@22.04 with latest/stable channel. The charm has
#            several bugs on Ubuntu 24.04:
#            - Self-signed certificate generation fails
#            The Terraform config includes workarounds for SSL generation.
#
# NOTE: Avoid 2.8/stable channel - it has a bug with missing DH parameters.
#
# CRITICAL: Set services="" in config to prevent duplicate frontend blocks
#           when using the website relation with landscape-server.
#
# Key config options:
#   services           - MUST be empty ("") to avoid duplicate frontends
#   ssl_cert           - TLS certificate (base64 encoded or "SELFSIGNED")
#   ssl_key            - TLS private key (base64 encoded)
#   default_timeouts   - Connection timeout settings

variable "haproxy" {
  description = "HAProxy charm configuration"
  type = object({
    app_name    = optional(string, "haproxy")
    channel     = optional(string, "latest/stable")
    revision    = optional(number)
    base        = optional(string, "ubuntu@22.04")
    units       = optional(number, 1)
    constraints = optional(string, "")
    config      = optional(map(string), {})
  })
  default = {}
}

# ----------------------------------------------------------------------------
# RabbitMQ
# ----------------------------------------------------------------------------
# Message broker for Landscape's async job processing.
# Channel 3.12/stable required for Ubuntu 24.04 support.
#
# Key config options:
#   consumer-timeout - Max time (ms) for consumers to ack messages
#                      Set high (259200000 = 3 days) for long-running jobs

variable "rabbitmq_server" {
  description = "RabbitMQ Server charm configuration"
  type = object({
    app_name    = optional(string, "rabbitmq-server")
    channel     = optional(string, "3.12/stable")
    revision    = optional(number)
    base        = optional(string, "ubuntu@24.04")
    units       = optional(number, 3)
    constraints = optional(string, "")
    config      = optional(map(string), {})
  })
  default = {}
}
