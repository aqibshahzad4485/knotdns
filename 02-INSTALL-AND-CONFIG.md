# Installation & Full Secured Configuration

## 1. Install Knot DNS (all 6 nodes)

```bash
apt-get update
apt-get install -y knot knot-dnsutils
systemctl enable knot
mkdir -p /etc/knot/keys /var/lib/knot
chown -R knot:knot /var/lib/knot /etc/knot
```
Open firewall for 53/udp+tcp between the six IPs (and to your resolvers/clients as
needed):
```bash
ufw allow from 10.10.10.0/24 to any port 53 proto tcp
ufw allow from 10.10.10.0/24 to any port 53 proto udp
```

## 2. Generate TSIG keys (run once, on A1, then distribute)

One key per replication relationship — 5 keys total. Never reuse a key across
relationships.

```bash
mkdir -p /root/knot-keys && cd /root/knot-keys
keymgr -t key_a1_a2 hmac-sha256 > key_a1_a2.conf
keymgr -t key_a1_a3 hmac-sha256 > key_a1_a3.conf
keymgr -t key_a1_b1 hmac-sha256 > key_a1_b1.conf
keymgr -t key_b1_b2 hmac-sha256 > key_b1_b2.conf
keymgr -t key_b1_b3 hmac-sha256 > key_b1_b3.conf
cat key_*.conf > all-keys.conf
```
Each line looks like:
```
key:
  - id: key_a1_b1
    algorithm: hmac-sha256
    secret: <base64-secret>
```
Copy `all-keys.conf` to `/etc/knot/keys/keys.conf` on **every** node (`scp` over an
already-secured channel, e.g. an existing management VPN/SSH — never plaintext).
Every node needs *all* key definitions (the secret is the shared symmetric key used
by both ends of that specific pairing), but each node will only reference the keys
relevant to it.

```bash
for h in 10.10.10.12 10.10.10.13 10.10.10.21 10.10.10.22 10.10.10.23; do
  scp /root/knot-keys/all-keys.conf root@$h:/etc/knot/keys/keys.conf
done
cp /root/knot-keys/all-keys.conf /etc/knot/keys/keys.conf   # on A1 itself
```

## 3. Config layout used below

Every node includes the shared keys file, then defines TSIG-bound `remote`s and
`acl`s (a `remote` carries the key for outbound AXFR/NOTIFY-send auth; an `acl`
carries the key for validating *inbound* NOTIFY/AXFR/transfer requests).

---
### A1 — `/etc/knot/knot.conf` (steady state: MASTER)
```yaml
include: /etc/knot/keys/keys.conf

server:
  listen: 10.10.10.11@53
  rundir: /run/knot
  user: knot:knot

log:
  - target: syslog
    any: info

mod-dnstap:
  - id: tap
    sink: "unix:/tmp/dnstap.sock"
    log-queries: on
    log-responses: on

remote:
  - id: site_a_slave1
    address: 10.10.10.12@53
    key: key_a1_a2
  - id: site_a_slave2
    address: 10.10.10.13@53
    key: key_a1_a3
  - id: site_b_primary
    address: 10.10.10.21@53
    key: key_a1_b1

acl:
  - id: allow_transfer
    address: [10.10.10.12, 10.10.10.13, 10.10.10.21]
    key: [key_a1_a2, key_a1_a3, key_a1_b1]
    action: transfer
  - id: allow_notify_from_b
    address: 10.10.10.21
    key: key_a1_b1
    action: notify

template:
  - id: default
    global-module: mod-dnstap/tap
    storage: /var/lib/knot
    file: "%s.zone"
    zonefile-sync: -1
    zonefile-load: difference
    journal-content: all
    serial-policy: unixtime

zone:
  - domain: domain.local
    # master: <UNSET in steady state — A1 is the authoritative master>
    notify: [site_a_slave1, site_a_slave2, site_b_primary]
    acl: [allow_transfer, allow_notify_from_b]
```

### A1 — after failover (SLAVE of B1) — only ONE line changes
```yaml
zone:
  - domain: domain.local
    master: site_b_primary                      # <- the only change
    notify: [site_a_slave1, site_a_slave2, site_b_primary]  # unchanged, static
    acl: [allow_transfer, allow_notify_from_b]               # unchanged, static
```

---
### A2 — `/etc/knot/knot.conf` (never changes)
```yaml
include: /etc/knot/keys/keys.conf

server:
  listen: 10.10.10.12@53
  user: knot:knot

remote:
  - id: local_primary
    address: 10.10.10.11@53
    key: key_a1_a2

acl:
  - id: allow_notify
    address: 10.10.10.11
    key: key_a1_a2
    action: notify

template:
  - id: default
    storage: /var/lib/knot
    file: "%s.zone"

zone:
  - domain: domain.local
    master: local_primary
    acl: allow_notify
```

### A3 — identical to A2, addresses/key swapped
```yaml
include: /etc/knot/keys/keys.conf

server:
  listen: 10.10.10.13@53
  user: knot:knot

remote:
  - id: local_primary
    address: 10.10.10.11@53
    key: key_a1_a3

acl:
  - id: allow_notify
    address: 10.10.10.11
    key: key_a1_a3
    action: notify

template:
  - id: default
    storage: /var/lib/knot
    file: "%s.zone"

zone:
  - domain: domain.local
    master: local_primary
    acl: allow_notify
```

---
### B1 — `/etc/knot/knot.conf` (steady state: SLAVE / standby master)
```yaml
include: /etc/knot/keys/keys.conf

server:
  listen: 10.10.10.21@53
  rundir: /run/knot
  user: knot:knot

mod-dnstap:
  - id: tap
    sink: "unix:/tmp/dnstap.sock"
    log-queries: on
    log-responses: on

remote:
  - id: site_b_slave1
    address: 10.10.10.22@53
    key: key_b1_b2
  - id: site_b_slave2
    address: 10.10.10.23@53
    key: key_b1_b3
  - id: site_a_primary
    address: 10.10.10.11@53
    key: key_a1_b1

acl:
  - id: allow_transfer
    address: [10.10.10.22, 10.10.10.23, 10.10.10.11]
    key: [key_b1_b2, key_b1_b3, key_a1_b1]
    action: transfer
  - id: allow_notify_from_a
    address: 10.10.10.11
    key: key_a1_b1
    action: notify

template:
  - id: default
    global-module: mod-dnstap/tap
    storage: /var/lib/knot
    file: "%s.zone"
    zonefile-sync: -1
    zonefile-load: difference
    journal-content: all
    serial-policy: unixtime

zone:
  - domain: domain.local
    master: site_a_primary
    notify: [site_b_slave1, site_b_slave2, site_a_primary]
    acl: [allow_transfer, allow_notify_from_a]
```

### B1 — after promotion (MASTER) — only ONE line changes
```yaml
zone:
  - domain: domain.local
    # master: <UNSET — B1 is now authoritative — the only change>
    notify: [site_b_slave1, site_b_slave2, site_a_primary]  # unchanged, static
    acl: [allow_transfer, allow_notify_from_a]               # unchanged, static
```

---
### B2 / B3 — identical pattern to A2/A3, with their own IPs and keys
```yaml
include: /etc/knot/keys/keys.conf

server:
  listen: 10.10.10.22@53   # .23 on B3
  user: knot:knot

remote:
  - id: local_primary
    address: 10.10.10.21@53
    key: key_b1_b2           # key_b1_b3 on B3

acl:
  - id: allow_notify
    address: 10.10.10.21
    key: key_b1_b2           # key_b1_b3 on B3
    action: notify

template:
  - id: default
    storage: /var/lib/knot
    file: "%s.zone"

zone:
  - domain: domain.local
    master: local_primary
    acl: allow_notify
```

## 4. First-time bring-up order

1. Bring up **A1** first (with the zone file placed at
   `/var/lib/knot/domain.local.zone` — your existing file is fine, just fix the
   stray Markdown-link artifact `[www.domain.local](https://www.domain.local)` → it
   must read `www.domain.local.  3600  A  10.10.10.10`).
2. `knotc zone-check domain.local` then `systemctl start knot`.
3. Bring up A2, A3, B1, B2, B3 — they'll AXFR on startup automatically once ACLs
   line up.
4. Verify on each: `knotc zone-status domain.local`.

## 5. Zone-file serial hygiene

`serial-policy: unixtime` (set above) means Knot auto-bumps SOA serial on every
committed change, removing the #1 cause of "forgot to bump serial" split-brain-like
symptoms (a stale-serial node refusing an update it thinks is older). Your current
zone's serial (`2026070209`) is a manually-formatted `YYYYMMDDnn` serial — unixtime
serials are numerically larger than that going forward, so the switch is safe and
one-directional; don't switch back to a smaller manual scheme later.
