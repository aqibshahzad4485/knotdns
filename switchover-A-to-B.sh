#!/usr/bin/env bash
# switchover-A-to-B.sh
# PLANNED switchover: Site A (A1) is currently MASTER and reachable.
# Promotes B1 to master, demotes A1 to slave, in the safe order:
#   1) force-sync B1 from A1 and confirm serial parity
#   2) DEMOTE A1 (master -> slave of B1)
#   3) confirm A1 committed
#   4) PROMOTE B1 (slave -> master)
#   5) verify
#
# Run from an admin/jump host with SSH key access to A1 and B1.
# Requires: preflight-check.sh in the same directory.

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

echo
echo "### Step 1/5: force B1 to fully sync from A1 before touching anything ###"
$SSH root@"$B1" "knotc zone-retransfer ${ZONE}"
sleep 3
A1_SERIAL=$(dig @"$A1" "$ZONE" SOA +short | awk '{print $3}')
B1_SERIAL=$(dig @"$B1" "$ZONE" SOA +short | awk '{print $3}')
echo "  A1 serial=$A1_SERIAL   B1 serial=$B1_SERIAL"
if [[ "$A1_SERIAL" != "$B1_SERIAL" ]]; then
  echo "  [ABORT] B1 is not in sync with A1 (serial mismatch). Fix replication"
  echo "          before switching over. No changes made."
  exit 1
fi
echo "  [OK] B1 is fully synced with A1."

confirm "About to DEMOTE A1 (master->slave) then PROMOTE B1 (slave->master). Proceed?"

echo
echo "### Step 2/5: DEMOTE A1 (master -> slave of B1) ###"
$SSH root@"$A1" bash -s <<EOF
set -e
knotc conf-begin
knotc conf-set zone[${ZONE}].master site_b_primary
knotc conf-commit
knotc zone-status ${ZONE}
EOF

echo
echo "### Step 3/5: confirm A1 is now slave and not serving as master ###"
sleep 2
A1_ROLE=$($SSH root@"$A1" "knotc zone-status ${ZONE}" | grep -oE 'role: (master|slave)' | awk '{print $2}')
if [[ "$A1_ROLE" != "slave" ]]; then
  echo "  [ABORT] A1 did not confirm slave role (got: $A1_ROLE). STOP — do NOT"
  echo "          promote B1 while A1's role is uncertain. Investigate manually."
  exit 1
fi
echo "  [OK] A1 confirmed role=slave."

echo
echo "### Step 4/5: PROMOTE B1 (slave -> master) ###"
$SSH root@"$B1" bash -s <<EOF
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
echo "Switchover A -> B complete. B1 (10.10.10.21) is now the master for ${ZONE}."
echo "A1, A2, A3 remain fully readable and now replicate from B1 via A1."
