# Landscape-HA

Deploy [Canonical Landscape](https://ubuntu.com/landscape) in **High Availability** on MAAS bare metal using Terraform with the Juju provider.

## Overview

This project provides Infrastructure as Code (IaC) for deploying Landscape Server - Canonical's systems management solution for Ubuntu - in a fully redundant, highly available configuration on bare metal machines managed by MAAS.

**Key Features:**
- **High Availability by default** - All components deployed with redundancy
- Deploys on **MAAS-provisioned bare metal** machines
- Uses existing **Juju controller** (maas_cloud)
- **Automatic failover** for PostgreSQL, RabbitMQ, and Landscape Server
- **Pure Terraform** - No additional tools required

## Architecture

```
                                    Clients
                                       │
                                       ▼
                               ┌─────────────┐
                               │   HAProxy   │
                               │    (AZ1)    │
                               │ TLS + Load  │
                               │  Balancing  │
                               └──────┬──────┘
                                      │
        ┌─────────────────────────────┼─────────────────────────────┐
        │                             │                             │
  ┌─────▼─────┐                 ┌─────▼─────┐                 ┌─────▼─────┐
  │ Landscape │                 │ Landscape │                 │ Landscape │
  │  Server   │                 │  Server   │                 │  Server   │
  │   (AZ1)   │                 │   (AZ2)   │                 │   (AZ3)   │
  └─────┬─────┘                 └─────┬─────┘                 └─────┬─────┘
        │                             │                             │
        └─────────────────────────────┼─────────────────────────────┘
                                      │
  ┌───────────────────────────────────┼───────────────────────────────────┐
  │                                   │                                   │
  │  ┌───────────┐             ┌───────────┐             ┌───────────┐    │
  │  │PostgreSQL │◄───────────►│PostgreSQL │◄───────────►│PostgreSQL │    │
  │  │  Primary  │  Streaming  │  Standby  │  Streaming  │  Standby  │    │
  │  │   (AZ1)   │ Replication │   (AZ2)   │ Replication │   (AZ3)   │    │
  │  └───────────┘             └───────────┘             └───────────┘    │
  │                                                                       │
  │  ┌───────────┐             ┌───────────┐             ┌───────────┐    │
  │  │ RabbitMQ  │◄───────────►│ RabbitMQ  │◄───────────►│ RabbitMQ  │    │
  │  │   (AZ1)   │   Cluster   │   (AZ2)   │   Cluster   │   (AZ3)   │    │
  │  └───────────┘             └───────────┘             └───────────┘    │
  └───────────────────────────────────────────────────────────────────────┘
```

## HA Components

| Component | Units | HA Mechanism | Failover |
|-----------|-------|--------------|----------|
| **PostgreSQL** | 3 | Patroni + Streaming Replication | Automatic |
| **RabbitMQ** | 3 | Clustered + Mirrored Queues | Automatic |
| **Landscape Server** | 3 | Stateless + Load Balanced | Automatic |
| **HAProxy** | 1 | Load Balancer | Single entry point |

## Prerequisites

### Required Infrastructure

| Component | Requirement |
|-----------|-------------|
| MAAS | Configured with available machines |
| Juju Controller | Bootstrapped on MAAS (`maas_cloud`) |
| Machines | **10 machines** available in MAAS pool |
| Availability Zones | 3 zones recommended (AZ1, AZ2, AZ3) |

### MAAS Configuration

It is needed pre-created VMs with the proper tags.

### Machine Requirements

| Role | Tag | Count | Minimum Specs |
|------|-----|-------|---------------|
| Landscape Server | `landscape` | 3 | 4 vCPU, 4GB RAM, 50GB disk |
| PostgreSQL | `landscapesql` | 3 | 4 vCPU, 4GB RAM, 100GB disk |
| RabbitMQ | `landscapeamqp` | 3 | 2 vCPU, 2GB RAM, 20GB disk |
| HAProxy | `landscapeha` | 1 | 2 vCPU, 2GB RAM, 20GB disk |
| **Total** | | **10** | |

### Zone Distribution

| Zone | Machines |
|------|----------|
| AZ1 | 1x landscape, 1x landscapesql, 1x landscapeamqp, 1x landscapeha |
| AZ2 | 1x landscape, 1x landscapesql, 1x landscapeamqp |
| AZ3 | 1x landscape, 1x landscapesql, 1x landscapeamqp |

### Required Software

```bash
# Install Opentofu
sudo snap install opentofu --classic

# Juju CLI (for management)
sudo snap install juju
```

## Quick Start

### 1. Clone the Repository

```bash
git clone <repository-url> landscape
cd landscape
```

### 2. Verify Juju Connection

```bash
juju switch maas_cloud
juju whoami
juju clouds
```

### 3. Create Configuration

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with your settings:

```hcl
cloud_name = "maas_cloud"

landscape_server = {
  constraints = "tags=landscape zones=AZ1,AZ2,AZ3"
}
```

### 4. Tag Machines in MAAS

```bash
# Using MAAS CLI
maas $PROFILE tag update-nodes landscape system_id=$SYS1,$SYS2,$SYS3
maas $PROFILE tag update-nodes landscapesql system_id=$SYS4,$SYS5,$SYS6
maas $PROFILE tag update-nodes landscapeamqp system_id=$SYS7,$SYS8,$SYS9
maas $PROFILE tag update-nodes landscapeha system_id=$SYS10
```

### 5. Deploy

```bash
tofu init
tofu plan
tofu apply
```

### 6. Access Landscape

```bash
# Get HAProxy address
juju status -m landscape haproxy --format yaml | \
  yq '.applications.haproxy.units[].public-address'
```

Access Landscape at `https://<haproxy-ip>/`

## Configuration

### terraform.tfvars

```hcl
# MAAS Cloud
cloud_name   = "maas_cloud"
cloud_region = "default"

# Model
model_name = "landscape"

# Landscape Server
landscape_server = {
  app_name    = "landscape-server"
  channel     = "latest/stable"
  base        = "ubuntu@24.04"
  units       = 3
  constraints = "tags=landscape zones=AZ1,AZ2,AZ3"
}

# PostgreSQL
postgresql = {
  app_name    = "postgresql"
  channel     = "14/stable"       # Required: 16/stable lacks pgsql interface
  base        = "ubuntu@22.04"    # Required for 14/stable
  units       = 3
  constraints = "tags=landscapesql zones=AZ1,AZ2,AZ3"
  config = {
    "plugin_plpython3u_enable"     = "true"
    "plugin_ltree_enable"          = "true"
    "plugin_intarray_enable"       = "true"
    "plugin_debversion_enable"     = "true"
    "plugin_pg_trgm_enable"        = "true"
    "experimental_max_connections" = "500"
  }
}

# HAProxy
haproxy = {
  app_name    = "haproxy"
  channel     = "latest/stable"
  base        = "ubuntu@22.04"    # Required: SSL generation fails on 24.04
  units       = 1
  constraints = "tags=landscapeha zones=AZ1"
  config = {
    "services"                    = ""  # CRITICAL: Prevents duplicate frontends
    "ssl_cert"                    = "SELFSIGNED"
    "default_timeouts"            = "queue 60000, connect 5000, client 120000, server 120000"
    "global_default_bind_options" = "no-tlsv10"
  }
}

# RabbitMQ
rabbitmq_server = {
  app_name    = "rabbitmq-server"
  channel     = "3.12/stable"
  base        = "ubuntu@24.04"
  units       = 3
  constraints = "tags=landscapeamqp zones=AZ1,AZ2,AZ3"
  config = {
    "consumer-timeout" = "259200000"
  }
}
```

## Production Configuration

### SSL/TLS Certificates

```hcl
haproxy = {
  config = {
    "ssl_cert" = "<base64-encoded-fullchain>"
    "ssl_key"  = "<base64-encoded-privkey>"
  }
}
```

### Landscape License

```hcl
landscape_server = {
  config = {
    "license_file" = "<base64-encoded-license>"
  }
}
```

### Admin Configuration

```hcl
# Admin credentials
landscape_admin_email              = "admin@example.com"
landscape_admin_name               = "Administrator"
landscape_admin_password_file      = "../../pcb-plus/secrets/landscape-password.txt"
landscape_registration_key_file    = "../../pcb-plus/secrets/landscape_registration_key.txt"

# Additional config via landscape_server
landscape_server = {
  config = {
    "root_url"        = "https://landscape.example.com"
    "smtp_relay_host" = "smtp.example.com"
  }
}
```

Password and registration key are read from their respective files automatically if
they exist. Each file should contain only the value (no newlines or extra whitespace).

Create the secret files:

```bash
mkdir -p ../../pcb-plus/secrets # (if it doesn't exist)
pwgen 16 1 > ../../pcb-plus/secrets/landscape-password.txt
pwgen 32 1 > ../../pcb-plus/secrets/landscape_registration_key.txt
chmod 600 ../../pcb-plus/secrets/landscape-password.txt ../../pcb-plus/secrets/landscape_registration_key.txt
```

### Landscape Client Configuration

After deployment, get the values needed to configure `landscape-client`:

```bash
tofu output
```

| Output | landscape-client config | Description |
|--------|------------------------|-------------|
| `landscape_url` | `url` | Message server URL (`https://<hostname>/message-system`) |
| `landscape_ping_url` | `ping-url` | Ping server URL (`http://<hostname>/ping`) |
| `ssl_cert_path` | `ssl-public-key` | Path to the exported SSL certificate |
| `registration_key` | `registration-key` | Client enrollment key (sensitive) |
| `account_name` | `account-name` | Landscape account name (`standalone`) |

To view the registration key:

```bash
tofu output -raw registration_key
```

## Operations

### Check Status

```bash
juju status -m landscape
juju status -m landscape --relations
```

### Verify HA

```bash
# PostgreSQL cluster
juju ssh -m landscape postgresql/leader 'patronictl list'

# RabbitMQ cluster
juju ssh -m landscape rabbitmq-server/0 'rabbitmqctl cluster_status'
```


### Backup PostgreSQL

```bash
juju run -m landscape postgresql/leader create-backup
juju run -m landscape postgresql/leader list-backups
```

### Destroy

```bash
tofu destroy
```

#### Or via Juju
```bash
juju destroy-model landscape --destroy-storage -y
```

## Project Structure

```
landscape-deploy/
├── README.md
├── main.tf                    # Main Terraform configuration
├── variables.tf               # Input variables
├── outputs.tf                 # Output values
├── terraform.tfvars.example   # Example configuration
└── .gitignore
```

## References

- [Canonical Landscape](https://ubuntu.com/landscape)
- [Landscape Server Charm](https://charmhub.io/landscape-server)
- [Charmed PostgreSQL](https://charmhub.io/postgresql)
- [Charmed RabbitMQ](https://charmhub.io/rabbitmq-server)
- [Terraform Juju Provider](https://registry.terraform.io/providers/juju/juju/latest/docs)
- [MAAS Documentation](https://maas.io/docs)

## License

See [LICENSE](LICENSE) for details.
