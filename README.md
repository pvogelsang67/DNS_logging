# DNS_logging

> **Disclaimer:** This solution is an independent community project and is not developed, approved, or supported by Infoblox.
> It is provided as-is, without warranty of any kind.
> Infoblox trademarks and product names are referenced solely to describe interoperability.
> For official Infoblox solutions and support, visit [infoblox.com](https://infoblox.com).

Logging DNS queries (DNSTap and RPZ events) to Elasticsearch with Infoblox Threat data enriching the RPZ logs.

## Architecture

| Container    | Image                  | Port(s)                        | Role                            |
|--------------|------------------------|--------------------------------|---------------------------------|
| es01         | Elasticsearch 9.3.1    | 9200                           | Log storage and indexing        |
| kibana       | Kibana 9.3.1           | 5601                           | Visualization dashboard         |
| logstash     | Logstash 9.3.1         | 514/UDP, 514/TCP               | DNS RPZ log ingestion pipeline  |
| dnscollector | dmachard/dnscollector  | 6000/TCP, 8080/TCP, 9165/TCP   | DNSTap collection and forwarding|

All four containers share an internal `esnet` bridge network so they can resolve each other by name.

## Requirements

- Ubuntu Server 20.04, 22.04, or 24.04
- Internet access (for pulling Docker images and cloning this repo)
- `sudo` / root privileges on the target host
- An Infoblox Cloud Services Portal (CSP) API key — required for TIDE threat data enrichment (see below)

## Infoblox CSP API Key

RPZ log enrichment with **Infoblox TIDE threat intelligence** requires a valid API key from the [Infoblox Cloud Services Portal (CSP)](https://csp.infoblox.com).

### What the API key is used for

The Logstash pipeline queries the Infoblox TIDE API to enrich RPZ-matched DNS log entries with threat context — including threat confidence scores, indicator type, and threat class.

Without a valid API key, TIDE enrichment will be skipped and the `TIDE Confidence` and related dashboard panels will not populate.

### How to obtain your API key

1. Log in to the [Infoblox CSP](https://csp.infoblox.com) with your Infoblox account credentials.
2. Navigate to **Administration → User Profile** (top-right avatar menu).
3. Select the **API Keys** tab.
4. Click **Create API Key**, give it a descriptive name (e.g. `DNS_logging`), and copy the generated key.

### Where the key is stored

The installer will prompt you for the key during setup and write it automatically to:

```
dns-rpz-logging/.env
```

as:

```env
TIDE_API_KEY=<your-key-here>
```

You can update the key at any time by editing that file and restarting the Logstash container:

```bash
sudo docker restart logstash
```

## Quick Install

Download the install script directly from GitHub and run it in a single command:

```bash
curl -fsSL https://raw.githubusercontent.com/pvogelsang67/DNS_logging/main/install.sh | sudo bash
```

> **Note:** Because the installer prompts for your CSP API key interactively, the one-liner above must be run in an interactive terminal (not piped non-interactively).
> If you need a fully non-interactive install, download the script first and pass the key via an environment variable:
>
> ```bash
> curl -O https://raw.githubusercontent.com/pvogelsang67/DNS_logging/main/install.sh
> chmod +x install.sh
> sudo TIDE_API_KEY="<your-key>" ./install.sh
> ```

Alternatively, download the script first so you can review it before running:

```bash
curl -O https://raw.githubusercontent.com/pvogelsang67/DNS_logging/main/install.sh
chmod +x install.sh
sudo ./install.sh
```

## What the Installer Does

1. Detects and removes any prior installation (containers and the `/opt/DNS_logging` directory)
2. Installs Docker CE and the Docker Compose plugin (skipped if already present)
3. Installs git (skipped if already present)
4. Clones this repository to `/opt/DNS_logging`
5. Prompts for your Infoblox CSP API key and writes it to `dns-rpz-logging/.env`
6. Sets `vm.max_map_count=262144` (required by Elasticsearch) and persists it in `/etc/sysctl.conf`
7. Starts Elasticsearch and Kibana, waits for both to be healthy, then starts Logstash and DNSCollector
8. Verifies all containers reach a running state
9. Automatically imports the pre-built Kibana dashboard
10. Prints a summary of service endpoints and management commands

## Post-Install Access

| Service                         | URL                              |
|---------------------------------|----------------------------------|
| Kibana Dashboard                | http://\<server-ip\>:5601        |
| Elasticsearch API               | http://\<server-ip\>:9200        |
| DNSCollector Web UI             | http://\<server-ip\>:8080        |
| DNSCollector Prometheus Metrics | http://\<server-ip\>:9165        |
| Syslog / RPZ ingest             | \<server-ip\>:514 (UDP + TCP)    |
| DNSTap ingest                   | \<server-ip\>:6000 (TCP)         |

## Configuring Infoblox NIOS

Once the stack is running, configure your Infoblox NIOS Grid Member(s) to forward DNS data to this system. There are two independent data streams — DNSTap for full DNS query/response telemetry, and syslog for RPZ hit events.

### DNSTap (DNS Query & Response Logging)

DNSTap streams all DNS queries and responses from NIOS to the DNSCollector container over TCP port 6000.

1. In **Grid Manager**, navigate to **Grid → Grid Manager → Members**.
2. Click the Grid Member you want to configure, then select **Edit**.
3. Go to the **DNS** tab → **Advanced** tab.
4. Under **DNS Logging**, enable **DNSTap**.
5. Set the **DNSTap Receiver** address to the IP of this logging server.
6. Set the **Port** to `6000` and the **Protocol** to `TCP` (Frame Streams).
7. Click **Save & Close**, then **Restart DNS** on the member to apply.

Repeat for each Grid Member you want to collect DNS telemetry from.

> **Note:** DNSTap must be supported by your NIOS version. It is available in NIOS 8.6 and later. Ensure TCP port 6000 is permitted between your Grid Members and this server.

### RPZ Syslog (Response Policy Zone Hit Logging)

The Logstash pipeline on port 514 is configured **exclusively for RPZ hit log entries**. No other syslog categories are defined in the pipeline — forwarding non-RPZ syslog traffic (e.g. DHCP, general DNS debug, audit logs) will result in those messages being dropped or causing parse errors.

**Configure the external syslog destination:**

1. In **Grid Manager**, navigate to **Grid → Grid Manager → Grid Properties → Edit**.
2. Select the **Monitoring** tab.
3. Under **Syslog**, click **Add** to create a new external syslog server.
4. Set the **Address** to the IP of this logging server.
5. Set the **Port** to `514`.
6. Set the **Transport** to `UDP` or `TCP` (either is supported).
7. Click **Save & Close**.

**Enable only the RPZ logging category:**

1. Navigate to **Grid → Grid Manager → Members**, select the member, and click **Edit**.
2. Go to the **DNS** tab → **Logging** section.
3. Enable the **RPZ** logging category.
4. Ensure all other logging categories (queries, responses, client, DNSSEC, etc.) remain **disabled** for this syslog destination. The Logstash pipeline has no filters defined for those formats.
5. Click **Save & Close**, then restart DNS services on the member to apply.

> **Important:** Only RPZ log events should be forwarded to port 514 on this server. Sending other syslog categories will not cause data loss in Elasticsearch but will generate pipeline errors in Logstash. Check `docker logs logstash` if you see unexpected parse failures.

---

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

| File                                           | Purpose                                                    |
|------------------------------------------------|------------------------------------------------------------|
| `docker-compose.yml`                           | Unified compose file (repo root)                           |
| `dns-rpz-logging/.env`                         | Logstash environment variables (including `TIDE_API_KEY`)  |
| `dns-rpz-logging/logstash/pipeline/`           | Logstash pipeline configs                                  |
| `dns-rpz-logging/logstash/config/logstash.yml` | Logstash settings                                          |
| `dnscollector/config.yml`                      | DNSCollector settings                                      |
| `dnscollector/.env`                            | DNSCollector environment variables                         |

## Kibana Dashboard

A pre-built Kibana dashboard is included as a saved object export at:
`elasticsearch/dnstap_dashboard.ndjson`

The installer imports this dashboard into Kibana automatically during setup (STEP 9). Navigate to **Dashboards** in the Kibana left sidebar to open it once the stack is running.

The dashboard provides 9 visualisation panels out of the box:

| Panel               | Description                                              |
|---------------------|----------------------------------------------------------|
| FQDN Queried        | Top domains being resolved                               |
| Who is Asking       | Top client IPs generating DNS queries                    |
| DNS Query Type      | Breakdown by record type (A, PTR, SOA, IXFR, SRV, etc.) |
| DNS Response Code   | NXDOMAIN, NXRRSET, REFUSED, NOTIMP and others            |
| DNS Server          | Query volume per DNS server                              |
| RPZ DNS Zone        | RPZ zones matching traffic                               |
| RPZ Action VIA      | Fully-qualified RPZ block entries triggered              |
| TIDE Confidence     | Distribution of Infoblox TIDE threat confidence scores   |
| Top 5 NXDOMAIN      | Most frequent non-existent domain lookups                |

### Manual Import (fallback)

If the automatic import did not complete during install, you can import the dashboard manually:

1. Open Kibana in your browser: `http://<server-ip>:5601`
2. Navigate to **Stack Management** (bottom-left gear icon) → **Kibana** → **Saved Objects**
3. Click the **Import** button (top-right)
4. Click **Select file** and browse to `/opt/DNS_logging/elasticsearch/dnstap_dashboard.ndjson`
5. Leave the import options at their defaults (check **Automatically overwrite conflicts** if reimporting)
6. Click **Import** — Kibana will confirm all objects were loaded successfully
7. Navigate to **Dashboards** in the left sidebar to open the DNSTap Dashboard

> **Note:** The dashboard requires data to be flowing through the pipeline (DNSCollector → Logstash → Elasticsearch) before any visualisations will populate. Allow a few minutes after the stack starts for the first records to appear.

## Open Source Attributions

| Component                         | Source                            | License             |
|-----------------------------------|-----------------------------------|---------------------|
| DNS-collector (DNSTap receiver)   | github.com/dmachard/DNS-collector | MIT                 |
| Elasticsearch / Kibana / Logstash | elastic.co                        | Elastic License 2.0 |

The `dnscollector` container is powered by [DNS-collector by Denis Machard](https://github.com/dmachard/DNS-collector) — a high-speed passive DNS log collector that acts as the missing piece between DNS servers and your data stack.
It receives DNSTap streams from DNS servers (Infoblox NIOS, BIND, Unbound, PowerDNS, etc.) on tcp/6000 and forwards them into the logging pipeline.

## Uninstall / Reinstall

Simply re-run the install script — it will detect and clean up any existing containers and files before performing a fresh install.

```bash
curl -fsSL https://raw.githubusercontent.com/pvogelsang67/DNS_logging/main/install.sh | sudo bash
```