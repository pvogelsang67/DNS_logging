# DNS_logging

> **Disclaimer:** This solution is an independent community project and is **not** developed, approved, or supported by Infoblox. It is provided as-is, without warranty of any kind. Infoblox trademarks and product names are referenced solely to describe interoperability. For official Infoblox solutions and support, visit [infoblox.com](https://www.infoblox.com).

Logging DNS queries (DNSTap and RPZ events) to Elasticsearch with Infoblox Threat data.

## Architecture

| Container | Image | Port(s) | Role |
|-----------|-------|---------|------|
| `es01` | Elasticsearch 9.3.1 | 9200 | Log storage and indexing |
| `kibana` | Kibana 9.3.1 | 5601 | Visualization dashboard |
| `logstash` | Logstash 9.3.1 | 514/UDP, 514/TCP | DNS RPZ log ingestion pipeline |
| `dnscollector` | dmachard/dnscollector | 6000/TCP, 8080/TCP, 9165/TCP | DNSTap collection and forwarding |

All four containers share an internal `esnet` bridge network so they can resolve each other by name.

## Requirements

- Ubuntu Server 20.04, 22.04, or 24.04
- Internet access (for pulling Docker images and cloning this repo)
- `sudo` / root privileges on the target host

## Quick Install

Download the install script directly from GitHub and run it in a single command:

```bash
curl -fsSL https://raw.githubusercontent.com/pvogelsang67/DNS_logging/main/install.sh | sudo bash
```

Alternatively, download the script first so you can review it before running:

```bash
curl -O https://raw.githubusercontent.com/pvogelsang67/DNS_logging/main/install.sh
chmod +x install.sh
sudo ./install.sh
```

## What the Installer Does

1. Detects and removes any prior installation (containers and the `/opt/DNS_logging` directory)
2. Installs **Docker CE** and the **Docker Compose plugin** (skipped if already present)
3. Installs **git** (skipped if already present)
4. Clones this repository to `/opt/DNS_logging`
5. Sets `vm.max_map_count=262144` (required by Elasticsearch) and persists it in `/etc/sysctl.conf`
6. Starts all four containers using the unified `docker-compose.yml` at the repo root
7. Waits for containers to initialise then verifies each one is in a **running** state
8. Prints a summary of service endpoints and management commands

## Post-Install Access

| Service | URL |
|---------|-----|
| Kibana Dashboard | `http://<server-ip>:5601` |
| Elasticsearch API | `http://<server-ip>:9200` |
| DNSCollector Web UI | `http://<server-ip>:8080` |
| DNSCollector Prometheus Metrics | `http://<server-ip>:9165` |
| Syslog / RPZ ingest | `<server-ip>:514` (UDP + TCP) |
| DNSTap ingest | `<server-ip>:6000` (TCP) |

## Manual Management

```bash
# Start all services
sudo docker compose -f /opt/DNS_logging/docker-compose.yml up -d

# Stop all services
sudo docker compose -f /opt/DNS_logging/docker-compose.yml down

# View logs
sudo docker logs es01
sudo docker logs kibana
sudo docker logs logstash
sudo docker logs dnscollector

# Live-follow a container's logs
sudo docker logs -f logstash

# Check status of all containers
sudo docker ps -a
```

## Configuration Files

| File | Purpose |
|------|---------|
| `docker-compose.yml` | Unified compose file (repo root) |
| `dns-rpz-logging/.env` | Logstash environment variables |
| `dns-rpz-logging/logstash/pipeline/` | Logstash pipeline configs |
| `dns-rpz-logging/logstash/config/logstash.yml` | Logstash settings |
| `dnscollector/config.yml` | DNSCollector settings |
| `dnscollector/.env` | DNSCollector environment variables |

## Kibana Dashboard

A pre-built Kibana dashboard is included as a saved object export at:

```
elasticsearch/dnstap_dashbaord.ndjson
```

The dashboard provides 9 visualisation panels out of the box:

| Panel | Description |
|-------|-------------|
| FQDN Queried | Top domains being resolved |
| Who is Asking | Top client IPs generating DNS queries |
| DNS Query Type | Breakdown by record type (A, PTR, SOA, IXFR, SRV, etc.) |
| DNS Response Code | NXDOMAIN, NXRRSET, REFUSED, NOTIMP and others |
| DNS Server | Query volume per DNS server |
| RPZ DNS Zone | RPZ zones matching traffic |
| RPZ Action VIA | Fully-qualified RPZ block entries triggered |
| TIDE Confidence | Distribution of Infoblox TIDE threat confidence scores |
| Top 5 NXDOMAIN | Most frequent non-existent domain lookups |

### Loading the Dashboard into Kibana

1. Open Kibana in your browser — `http://<server-ip>:5601`
2. Navigate to **Stack Management** (bottom-left gear icon) → **Kibana** → **Saved Objects**
3. Click the **Import** button (top-right)
4. Click **Select file** and browse to `elasticsearch/dnstap_dashbaord.ndjson` in the cloned repo at `/opt/DNS_logging/elasticsearch/dnstap_dashbaord.ndjson`
5. Leave the import options at their defaults (check **Automatically overwrite conflicts** if reimporting)
6. Click **Import** — Kibana will confirm all objects were loaded successfully
7. Navigate to **Dashboards** in the left sidebar to open the **DNSTap Dashboard**

> **Note:** The dashboard requires data to be flowing through the pipeline (DNSCollector → Logstash → Elasticsearch) before any visualisations will populate. Allow a few minutes after the stack starts for the first records to appear.

## Open Source Attributions

| Component | Source | License |
|-----------|--------|---------|
| **DNS-collector** (DNSTap receiver) | [github.com/dmachard/DNS-collector](https://github.com/dmachard/DNS-collector) | MIT |
| **Elasticsearch / Kibana / Logstash** | [elastic.co](https://www.elastic.co) | Elastic License 2.0 |

The `dnscollector` container is powered by **[DNS-collector](https://github.com/dmachard/DNS-collector)** by Denis Machard — a high-speed passive DNS log collector that acts as the missing piece between DNS servers and your data stack. It receives DNSTap streams from DNS servers (Infoblox NIOS, BIND, Unbound, PowerDNS, etc.) on `tcp/6000` and forwards them into the logging pipeline.

## Uninstall / Reinstall

Simply re-run the install script — it will detect and clean up any existing containers and files before performing a fresh install.

```bash
curl -fsSL https://raw.githubusercontent.com/pvogelsang67/DNS_logging/main/install.sh | sudo bash
```