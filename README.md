# Highly Available Knot DNS Architecture

This repository documents the deployment of a highly available, multi-datacenter DNS architecture using Knot DNS, Keepalived, and Vector for telemetry. 

The architecture provides active-standby zone management with automatic failover via Virtual IP (VIP) floating, secure zone transfers using TSIG keys, and real-time query logging to ClickHouse.

## Network Topology

* **Datacenter A (Site A)**
    * Knot-A1 (Primary/Master): `10.10.10.11`
    * Slaves: `10.10.10.12`, `10.10.10.13`
* **Datacenter B (Site B)**
    * Knot-B1 (Standby/Secondary): `10.10.20.11`
    * Slaves: `10.10.20.12`, `10.10.20.13`
* **Virtual IP (VIP)**: `10.10.30.11` (Floats between Knot-A1 and Knot-B1)

---

## 1. Security: Generating TSIG Keys

Zone transfers (AXFR/IXFR) between datacenters must be authenticated. Generate a shared TSIG key on either node.

```bash
# Generate a 256-bit HMAC-SHA256 key
keymgr -t key_transfer hmac-sha256
```
This outputs a string like `key_transfer hmac-sha256 <BASE64_KEY>`. You will use this in the Knot configuration.

---

## 2. Knot DNS Configuration

Install Knot and the DNSTAP module on Debian 12:
```bash
sudo apt update && sudo apt install -y knot knot-module-dnstap
```

### Knot-A1 Configuration (`/etc/knot/knot.conf`)

```yaml
server:
  listen: [10.10.10.11@53, 10.10.30.11@53]

# Add the TSIG key generated earlier
key:
  - id: key_transfer
    algorithm: hmac-sha256
    secret: "<BASE64_KEY>"

mod-dnstap:
  - id: tap
    sink: "unix:/run/knot/dnstap/dnstap.sock"
    log-queries: on
    log-responses: on

remote:
  - id: site_a_slave1
    address: 10.10.10.12@53
    key: key_transfer
  - id: site_a_slave2
    address: 10.10.10.13@53
    key: key_transfer
  - id: site_b_primary
    address: 10.10.20.11@53
    key: key_transfer

acl:
  - id: allow_transfer
    address: [10.10.10.12, 10.10.10.13, 10.10.20.11]
    action: transfer
    key: key_transfer
  - id: allow_notify_from_b
    address: 10.10.20.11 # change to GW if NAT Enabled
    action: notify
    key: key_transfer

template:
  - id: default
    global-module: mod-dnstap/tap
    storage: /var/lib/knot
    file: "%s.zone"

zone:
  - domain: domain.local
    notify: [site_a_slave1, site_a_slave2, site_b_primary]
    acl: [allow_transfer, allow_notify_from_b]
  - domain: domain.dev
    notify: [site_a_slave1, site_a_slave2, site_b_primary]
    acl: [allow_transfer, allow_notify_from_b]
```

### Knot-B1 Configuration (`/etc/knot/knot.conf`)

```yaml
server:
  listen: [10.10.20.11@53, 10.10.30.11@53]

key:
  - id: key_transfer
    algorithm: hmac-sha256
    secret: "<BASE64_KEY>"

mod-dnstap:
  - id: tap
    sink: "unix:/run/knot/dnstap/dnstap.sock"
    log-queries: on
    log-responses: on

remote:
  - id: site_b_slave1
    address: 10.10.20.12@53
    key: key_transfer
  - id: site_b_slave2
    address: 10.10.20.13@53
    key: key_transfer
  - id: site_a_primary
    address: 10.10.10.11@53
    key: key_transfer

acl:
  - id: allow_transfer
    address: [10.10.20.12, 10.10.20.13, 10.10.10.11]
    action: transfer
    key: key_transfer
  - id: allow_notify_from_a
    address: 10.10.10.11 # change to GW if NAT Enabled
    action: notify
    key: key_transfer

template:
  - id: default
    global-module: mod-dnstap/tap
    storage: /var/lib/knot
    file: "%s.zone"

zone:
  - domain: domain.local
    master: site_a_primary
    notify: [site_b_slave1, site_b_slave2, site_a_primary]
    acl: [allow_transfer, allow_notify_from_a]
  - domain: domain.dev
    master: site_a_primary
    notify: [site_b_slave1, site_b_slave2, site_a_primary]
    acl: [allow_transfer, allow_notify_from_a]
```

---

## 3. High Availability & Failover

Keepalived manages the VIP and triggers the role mutation script when nodes fail or recover.

### The Mutation Script
Deploy this to `/usr/local/bin/knot-role.sh` on **both** A1 and B1. Make it executable (`chmod +x /usr/local/bin/knot-role.sh`).

```bash
#!/bin/bash
# /usr/local/bin/knot-role.sh
# Invoked by Keepalived state changes

ACTION=$1
REMOTE_ID=$2
ACL_ID=$3
ZONES=("domain.local" "domain.dev")

knotc conf-begin

if [ "$ACTION" == "promote" ]; then
    for ZONE in "${ZONES[@]}"; do
        knotc conf-unset zone[$ZONE].master
        knotc conf-unset zone[$ZONE].acl $ACL_ID
    done
elif [ "$ACTION" == "demote" ]; then
    for ZONE in "${ZONES[@]}"; do
        knotc conf-set zone[$ZONE].master $REMOTE_ID
        knotc conf-set zone[$ZONE].acl $ACL_ID
    done
fi

knotc conf-commit

for ZONE in "${ZONES[@]}"; do
    knotc zone-reload $ZONE
    [ "$ACTION" == "demote" ] && knotc zone-retransfer $ZONE
done
```

### Keepalived Config (`/etc/keepalived/keepalived.conf`)

**For Knot-A1 (Priority 150):**
```text
vrrp_instance VI_KNOT {
    state MASTER
    interface eth0
    virtual_router_id 53
    priority 150
    advert_int 1
    
    unicast_src_ip 10.10.10.11
    unicast_peer { 10.10.20.11 }
    
    virtual_ipaddress { 10.10.30.11/32 }
    
    notify_master "/usr/local/bin/knot-role.sh promote site_b_primary allow_notify_from_b"
    notify_backup "/usr/local/bin/knot-role.sh demote site_b_primary allow_notify_from_b"
}
```

**For Knot-B1 (Priority 100):**
```text
vrrp_instance VI_KNOT {
    state BACKUP
    interface eth0
    virtual_router_id 53
    priority 100
    advert_int 1
    
    unicast_src_ip 10.10.20.11
    unicast_peer { 10.10.10.11 }
    
    virtual_ipaddress { 10.10.30.11/32 }
    
    notify_master "/usr/local/bin/knot-role.sh promote site_a_primary allow_notify_from_a"
    notify_backup "/usr/local/bin/knot-role.sh demote site_a_primary allow_notify_from_a"
}
```

---

## 4. Slave Configuration

All slaves (A-side and B-side) point to the Keepalived VIP (`10.10.30.1`). They will seamlessly pull from whichever node is currently holding the VIP and acting as the master.

```yaml
# /etc/knot/knot.conf on all Slaves
server:
  listen: <LOCAL_IP>@53

key:
  - id: key_transfer
    algorithm: hmac-sha256
    secret: "<BASE64_KEY>"

remote:
  - id: master_vip
    address: 10.10.20.1@53
    key: key_transfer

acl:
  - id: allow_notify
    address: 10.10.30.1
    action: notify
    key: key_transfer

zone:
  - domain: domain.local
    master: master_vip
    acl: allow_notify
  - domain: domain.dev
    master: master_vip
    acl: allow_notify
```

---

## 5. Telemetry Pipeline

Knot DNSTAP writes to a local UNIX socket. Vector parses the protobuf data and ships it directly to ClickHouse.

### Socket Permissions Setup
```bash
sudo mkdir -p /run/knot/dnstap
sudo chown knot:knot /run/knot/dnstap
```

### Vector Configuration (`/etc/vector/vector.yaml`)
```yaml
sources:
  knot_dnstap:
    type: dnstap
    socket_path: /run/knot/dnstap/dnstap.sock

transforms:
  format_logs:
    type: remap
    inputs: ["knot_dnstap"]
    source: |
      .timestamp = now()
      .query_name = .message.query_name
      .query_type = .message.query_type
      .response_code = .message.response_code
      .source_ip = .message.query_address

sinks:
  clickhouse_db:
    type: clickhouse
    inputs: ["format_logs"]
    endpoint: http://<CLICKHOUSE_IP>:8123
    database: dns_metrics
    table: query_logs
    auth:
      strategy: basic
      user: default
      password: <PASSWORD>
```

### ClickHouse Initialization
```sql
CREATE DATABASE IF NOT EXISTS dns_metrics;

CREATE TABLE IF NOT EXISTS dns_metrics.query_logs (
    timestamp DateTime,
    query_name String,
    query_type String,
    response_code String,
    source_ip String
) ENGINE = MergeTree()
ORDER BY timestamp;
```
