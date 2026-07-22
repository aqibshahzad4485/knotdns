#!/usr/bin/env bash
# recover-A1-post-disaster.sh
# Run LOCALLY ON A1 (not from the jump host) the moment it comes back after
# an outage that was resolved by emergency-promote-B1.sh. This blocks A1
# from answering on port 53 until it has been forced into slave mode and
# resynced from B1, closing the race window where a rebooted A1 could
# briefly resume master duties and collide with B1.
#
# Usage: run as root on A1 itself.

set -euo pipefail
ZONE="domain.local"
B1="10.10.10.21"

echo "### 1/5: Blocking inbound DNS (53/tcp+udp) while we fix role ###"
iptables -I INPUT -p udp --dport 53 -j DROP
iptables -I INPUT -p tcp --dport 53 -j DROP

echo "### 2/5: Ensuring knot is running so knotc can talk to it ###"
systemctl start knot
sleep 2

echo "### 3/5: Forcing A1 into slave mode (master=site_b_primary) ###"
knotc conf-begin
knotc conf-set zone[${ZONE}].master site_b_primary
knotc conf-commit

echo "### 4/5: Forcing a fresh AXFR/IXFR from B1 to discard any stale local state ###"
knotc zone-retransfer ${ZONE}
sleep 3

echo "### 5/5: Verifying role and serial before reopening port 53 ###"
STATUS=$(knotc zone-status ${ZONE})
echo "$STATUS"
ROLE=$(echo "$STATUS" | grep -oE 'role: (master|slave)' | awk '{print $2}')

LOCAL_SERIAL=$(dig @127.0.0.1 "$ZONE" SOA +short | awk '{print $3}')
REMOTE_SERIAL=$(dig @"$B1" "$ZONE" SOA +short | awk '{print $3}')
echo "Local serial=$LOCAL_SERIAL   B1 serial=$REMOTE_SERIAL"

if [[ "$ROLE" != "slave" ]]; then
  echo "[ABORT] Role is '$ROLE', not 'slave'. DO NOT open port 53. Investigate"
  echo "        manually -- leaving A1 firewalled off until fixed."
  exit 1
fi
if [[ "$LOCAL_SERIAL" != "$REMOTE_SERIAL" ]]; then
  echo "[ABORT] Serial mismatch after retransfer. DO NOT open port 53."
  echo "        Investigate connectivity/ACL/TSIG between A1 and B1."
  exit 1
fi

echo "### All checks passed. Reopening port 53. ###"
iptables -D INPUT -p udp --dport 53 -j DROP
iptables -D INPUT -p tcp --dport 53 -j DROP

echo "A1 has safely rejoined as a SLAVE of B1. Zone is in sync."
echo "It is now safe (once you're ready) to run failback-B-to-A.sh from the"
echo "admin host to restore A1 as the primary master, if desired."
