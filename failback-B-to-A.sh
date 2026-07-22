#!/usr/bin/env bash
# failback-B-to-A.sh
# PLANNED failback: Site B (B1) is currently MASTER and reachable, A1 has
# recovered and is healthy. Restores A1 as master, B1 back to standby, in the
# safe order:
#   1) force-sync A1 from B1 and confirm serial parity
#   2) DEMOTE B1 (master -> slave of A1)
#   3) confirm B1 committed
#   4) PROMOTE A1 (slave -> master)
#   5) verify
#
# Run from an admin/jump host with SSH key access to A1 and B1.
# Requires: preflight-check.sh in the same directory.
#
# IMPORTANT: only run this after confirming A1's config was actually fixed
# post-disaster (see 04-RUNBOOK.md "post-disaster recovery of A1") -- i.e.
# A1 must currently show role=slave, master=site_b_primary, NOT role=master.

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ZONE="domain.local"
A1="10.10.10.11"
B1="10.10.10.21"
SSH="ssh -o BatchMode=yes -o ConnectTimeout=5"

confirm() {
  read -r -p "$1 [type YES to continue]: " ans
  [[ "$ans" == "YES" ]] || { echo "Aborted."; exit 1; }
}

echo "### Step 0/5: preflight check ###"
"$DIR/preflight-check.sh" || confirm "Preflight reported warnings above. Continue anyway?"

A1_ROLE=$($SSH root@"$A1" "knotc zone-status ${ZONE}" | grep -oE 'role: (master|slave)' | awk '{print $2}')
if [[ "$A1_ROLE" != "slave" ]]; then
  echo "[ABORT] A1 currently reports role=$A1_ROLE, expected 'slave'. Do NOT"
  echo "        proceed -- if A1 already thinks it's master, failing back now"
  echo "        would create split-brain. Fix A1's config first."
  exit 1
fi

echo
echo "### Step 1/5: force A1 to fully sync from B1 before touching anything ###"
$SSH root@"$A1" "knotc zone-retransfer ${ZONE}"
sleep 3
A1_SERIAL=$(dig @"$A1" "$ZONE" SOA +short | awk '{print $3}')
B1_SERIAL=$(dig @"$B1" "$ZONE" SOA +short | awk '{print $3}')
echo "  A1 serial=$A1_SERIAL   B1 serial=$B1_SERIAL"
if [[ "$A1_SERIAL" != "$B1_SERIAL" ]]; then
  echo "  [ABORT] A1 is not in sync with B1 (serial mismatch). Fix replication"
  echo "          before failing back. No changes made."
  exit 1
fi
echo "  [OK] A1 is fully synced with B1."

confirm "About to DEMOTE B1 (master->slave) then PROMOTE A1 (slave->master). Proceed?"

echo
echo "### Step 2/5: DEMOTE B1 (master -> slave of A1) ###"
$SSH root@"$B1" bash -s <<EOF
set -e
knotc conf-begin
knotc conf-set zone[${ZONE}].master site_a_primary
knotc conf-commit
knotc zone-status ${ZONE}
EOF

echo
echo "### Step 3/5: confirm B1 is now slave ###"
sleep 2
B1_ROLE=$($SSH root@"$B1" "knotc zone-status ${ZONE}" | grep -oE 'role: (master|slave)' | awk '{print $2}')
if [[ "$B1_ROLE" != "slave" ]]; then
  echo "  [ABORT] B1 did not confirm slave role (got: $B1_ROLE). STOP — do NOT"
  echo "          promote A1 while B1's role is uncertain. Investigate manually."
  exit 1
fi
echo "  [OK] B1 confirmed role=slave."

echo
echo "### Step 4/5: PROMOTE A1 (slave -> master) ###"
$SSH root@"$A1" bash -s <<EOF
set -e
knotc conf-begin
knotc conf-unset zone[${ZONE}].master
knotc conf-commit
knotc zone-status ${ZONE}
EOF

echo
echo "### Step 5/5: verify final state ###"
sleep 2
"$DIR/preflight-check.sh" || true
echo
echo "Failback B -> A complete. A1 (10.10.10.11) is master again for ${ZONE}."
