# Knot DNS Dual-Site HA — Architecture & Design

## 1. Topology

```
                         SITE A (primary)                         SITE B (backup / DR)
                    ┌───────────────────────┐                ┌───────────────────────┐
                    │   A1  10.10.10.11     │  AXFR/IXFR      │   B1  10.10.10.21     │
                    │   ROLE: MASTER        │◄───────────────►│   ROLE: STANDBY MASTER│
                    │   (toggle point)      │   NOTIFY both    │   (toggle point)      │
                    └──────────┬────────────┘   ways           └──────────┬────────────┘
                     AXFR/IXFR │  NOTIFY                          AXFR/IXFR│  NOTIFY
                 ┌─────────────┴─────────────┐                ┌───────────┴─────────────┐
                 ▼                           ▼                ▼                          ▼
        A2 10.10.10.12               A3 10.10.10.13    B2 10.10.10.22            B3 10.10.10.23
        ROLE: SLAVE (fixed)          ROLE: SLAVE (fixed) ROLE: SLAVE (fixed)      ROLE: SLAVE (fixed)
```

**Only two nodes ever change role: A1 and B1.** A2, A3, B2, B3 are permanent slaves of
their local site head (A1 or B1 respectively) and their config **never changes** during
a switchover — this is what makes the whole design safe and simple.

## 2. The golden rule (split-brain prevention)

> At any instant, **at most one** of {A1, B1} may be configured *without* a `master:`
> statement for `domain.local`.

If both are masterless at the same time → both accept independent updates → zone
diverges → **split-brain**. If both have a `master:` statement at the same time →
nobody is authoritative → zone goes stale (safe, but broken).

The safe transition sequence is therefore always:

**DEMOTE the current master to slave first → confirm it committed → THEN promote the
new node to master.**

This produces a short window (seconds) where *neither* node is a master. That is
**safe**: existing slaves keep serving cached answers from their last zonefile; you
simply cannot push a new update during that window. Never do the reverse order
(promote-then-demote), because that creates a window where **both** are masters —
the actual dangerous case.

## 3. What actually changes between roles

Looking closely at your configs, both the ACLs (`allow_transfer`,
`allow_notify_from_a`, `allow_notify_from_b`) **and** the `notify:` lists on A1 and
B1 already include the *other* head permanently, in both directions, regardless of
which one is currently master. That's actually the right instinct in your original
config — it means role is controlled by **exactly one thing**:

| Item | Master role | Slave role |
|---|---|---|
| `zone[domain.local].master` | unset | set to the remote ID of the other head (`site_b_primary` / `site_a_primary`) |

Everything else — ACLs, transfer permissions, remotes, notify targets — stays
**identical, permanently, in both roles**. A slave that includes its own upstream
master in its `notify:` list, or an ACL that permits NOTIFY from a peer that
currently has no reason to send one, is harmless (Knot just ignores an
unnecessary/duplicate NOTIFY — the receiver compares SOA serials and no-ops if
nothing is newer). The payoff is huge operationally: promoting or demoting a node
is a **single `knotc conf-set`/`conf-unset` command**, not a multi-key edit. Fewer
keys touched during an incident means fewer chances of a typo turning into a real
split-brain.

A1/B1 also each keep serving AXFR/NOTIFY **downward** to their own local slaves
(A2/A3 or B2/B3) regardless of whether they are currently master or slave of the
*other* site — this is normal Knot "relay"/chained-secondary behavior and requires
no config change on A2, A3, B2, B3 ever.

## 4. Security: TSIG everywhere

Your current ACLs are IP-only. On a DR/HA setup handling NOTIFY/AXFR and (implicitly)
the ability to become authoritative, IP-only ACLs are spoofable. Add TSIG keys to
every remote/ACL pair. See `02-INSTALL-AND-CONFIG.md` for full key generation and
config.

## 5. Roles summary table (normal / steady state)

| Node | IP | Zone role | Local slaves it serves | Upstream master |
|---|---|---|---|---|
| A1 | 10.10.10.11 | MASTER | A2, A3 (+ replicates to B1) | none |
| A2 | 10.10.10.12 | slave | – | A1 |
| A3 | 10.10.10.13 | slave | – | A1 |
| B1 | 10.10.10.21 | slave (standby master) | B2, B3 | A1 |
| B2 | 10.10.10.22 | slave | – | B1 |
| B3 | 10.10.10.23 | slave | – | B1 |

## 6. Roles after failover to Site B

| Node | Zone role | Upstream master |
|---|---|---|
| B1 | **MASTER** | none |
| B2, B3 | slave | B1 |
| A1 | slave (standby master) | B1 |
| A2, A3 | slave | A1 |

## 7. Disaster (unplanned) vs. planned switchover

- **Planned** (maintenance, DR test, scheduled failback): both A1 and B1 are reachable.
  Always demote-then-promote as above, and verify SOA serial parity first.
- **Disaster** (A1 is dead/unreachable): you cannot "demote" a dead node remotely.
  Promote B1 immediately (RTO first). **Critical:** when A1 eventually comes back
  online, it must not be allowed to resume as an un-demoted master before you fix
  its config — see the "post-disaster recovery" procedure in
  `04-RUNBOOK.md`. Practical mitigation: keep the Knot service **stopped** on boot
  after any unexplained A-site outage (e.g. via a boot flag / systemd override)
  until an operator confirms role, or firewall off port 53/udp+tcp inbound to A1
  from A2/A3/B1 until config is confirmed. The scripts in this guide implement
  this as an automatic safety check.

## 8. Why `knotc conf-set`/`conf-unset` persists across restarts

Knot keeps a live **configuration database** (`/var/lib/knot/confdb`) separate from
the YAML file. `knotc conf-begin/conf-set/conf-commit` edits that live DB directly and
is what the running daemon (and any restart of it) actually uses — the original
`/etc/knot/knot.conf` YAML is only re-read if you explicitly re-import it
(`knot -c ... --confdb` / `keymgr`/`knotc conf-import`, out of scope here). This is
good news operationally: a role change survives a `systemctl restart knot`. It is
bad news if you edit `knot.conf` by hand expecting it to take effect — it won't,
until you re-import it. **Rule: after the initial install, all changes to
`domain.local`'s role are made only via `knotc conf-*`, never by hand-editing
`knot.conf` again.** Keep `knot.conf` in git as the documented "day-0" baseline only.
