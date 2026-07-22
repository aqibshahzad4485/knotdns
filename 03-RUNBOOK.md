# Operational Runbook

Scripts referenced below live in `scripts/`. Run them from an **admin/jump host**
that has root SSH-key access to all six nodes, unless noted "run locally".

## 1. Everyday health check

```bash
./scripts/preflight-check.sh
```
Safe to run any time, any frequency (put it in cron/monitoring, e.g. every 5 min,
alert on non-zero exit).

Manual per-node one-liners:
```bash
knotc zone-status domain.local        # role, serial, last transfer time
dig @<node-ip> domain.local SOA +short
knotc zone-stats domain.local         # transfer error counters (Knot 3.5+)
journalctl -u knot -f                 # live log
```

## 2. Planned switchover: Site A active → Site B active

Pre-req: both A1 and B1 reachable, A1 currently master.

```bash
./scripts/switchover-A-to-B.sh
```
This: preflight → force B1 sync + serial check → demote A1 → confirm →
promote B1 → verify. If any step fails it stops **before** promoting the new
master, so worst case you're left with two slaves (safe, read-only) — never
two masters.

## 3. Planned failback: Site B active → Site A active

Pre-req: both reachable, A1 confirmed already in slave mode (i.e. it either
never had an unplanned outage, or `recover-A1-post-disaster.sh` already ran
successfully).

```bash
./scripts/failback-B-to-A.sh
```
Same safety pattern, mirrored.

## 4. Disaster: A1 is down/unreachable, need Site B live now

```bash
./scripts/emergency-promote-B1.sh
```
This does **not** wait for or touch A1 — it double-checks A1 is truly
unreachable, then promotes B1 immediately. RTO-first, by design.

## 5. Post-disaster: A1 has come back online

**Do this before A1 is exposed to the shared network / before any resolver
sends it traffic.** If A1 is on a VM/host you control, isolate it (pull the
network cable, disable the interface, or firewall it) as part of your boot
sequence until this runs.

Run **locally on A1**:
```bash
./scripts/recover-A1-post-disaster.sh
```
This blocks port 53 with `iptables`, forces A1 into slave mode, force-pulls a
fresh copy from B1, checks serial parity, and only then reopens port 53. If
anything looks wrong it leaves port 53 blocked and exits non-zero — a human
must intervene rather than silently exposing a possibly-master A1.

**Hardening tip:** wire this script into a systemd unit
(`recover-a1.service`, `Before=knot.service`, `WantedBy=multi-user.target`)
so it runs automatically on every boot of A1, permanently removing the
race condition instead of relying on an operator remembering to run it.

## 6. Recovering from an *actual* split-brain (both A1 and B1 report master)

This should never happen if the scripts above are used, but if it does
(e.g., someone bypassed the scripts and ran raw `knotc` on both sides):

1. **Stop accepting writes immediately.** Freeze both zones so neither can
   diverge further:
   ```bash
   ssh root@10.10.10.11 knotc zone-freeze domain.local
   ssh root@10.10.10.21 knotc zone-freeze domain.local
   ```
2. Compare the two zone files / SOA serials and **decide which side's data is
   authoritative** (usually: whichever side clients were actually resolving
   against most recently, or whichever has the change you actually intended).
   ```bash
   ssh root@10.10.10.11 "knotc zone-status domain.local; dig @10.10.10.11 domain.local SOA"
   ssh root@10.10.10.21 "knotc zone-status domain.local; dig @10.10.10.21 domain.local SOA"
   diff <(ssh root@10.10.10.11 cat /var/lib/knot/domain.local.zone) \
        <(ssh root@10.10.10.21 cat /var/lib/knot/domain.local.zone)
   ```
3. On the **losing** side, demote it to slave (`conf-set master ...`) — do
   **not** delete its zone file yet, keep it for forensics/diff.
4. `knotc zone-thaw domain.local` on both once only one is master.
5. Force the (now single) slave to retransfer: `knotc zone-retransfer domain.local`.
6. Manually re-apply any changes that only existed on the losing side's
   diverged copy, via a normal update on the winning master.
7. Run `preflight-check.sh` to confirm single-master state before resuming
   normal operations.

## 7. DR test checklist (do this quarterly, in a maintenance window)

- [ ] `preflight-check.sh` clean before starting
- [ ] Make a trivial, clearly-labeled test record change on A1 (e.g. a TXT
      record with a timestamp), confirm it appears on B1/B2/B3 via `dig`
- [ ] Run `switchover-A-to-B.sh`
- [ ] Confirm all 6 nodes answer queries correctly (`dig` each node directly)
- [ ] Make a test change on B1 now, confirm it propagates to A1/A2/A3
- [ ] Run `failback-B-to-A.sh`
- [ ] Confirm all 6 nodes correct again, remove the test record
- [ ] Simulate disaster: `iptables -A INPUT -s <B1-jump-ip> -j DROP` style
      block on A1, or actually stop `knot` on A1, then run
      `emergency-promote-B1.sh`, then restart A1 and run
      `recover-A1-post-disaster.sh`, then `failback-B-to-A.sh`
- [ ] File results / timing (RTO actually achieved) in your DR log

## 8. Monitoring signals worth alerting on

- `knotc zone-status` role flips unexpectedly (compare against last-known-good
  stored role, e.g. in your monitoring system) — could indicate a manual
  mistake or a runaway automation.
- Both A1 and B1 simultaneously report `role: master` → **page immediately**,
  this is split-brain.
- Both A1 and B1 simultaneously report `role: slave` → warn (zone is
  read-only fleet-wide, not an emergency but needs attention).
- SOA serial not advancing on any slave for longer than your expected update
  cadence → replication stuck (check ACL/TSIG/firewall between that node and
  its master).
- `knotc zone-stats` transfer failure counters increasing.

## 9. Fix needed in your current zone file

Your dumped zone file has a stray Markdown artifact from a copy/paste that
will break parsing:
```
[www.domain.local](https://www.domain.local).       3600    A       10.10.10.10
```
should be:
```
www.domain.local.       3600    A       10.10.10.10
```
Run `knotc zone-check domain.local` after fixing it, before it's ever
transferred out — a bad record will otherwise get pushed to every slave.
