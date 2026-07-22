#!/usr/bin/env bash
# emergency-promote-B1.sh
# DISASTER failover: A1 is unreachable/dead. Do NOT wait for it.
# Promotes B1 to master immediately. Does not touch A1 (it's assumed down).
#
# Run from an admin/jump host with SSH key access to B1.
#
# After running this, you MUST run recover-A1-post-disaster.sh ON A1 the
# moment it comes back, BEFORE it is allowed to answer queries on the
# shared network -- otherwise A1 may resume acting as an un-demoted master
# and you will get real split-brain the instant it reconnects.

set -euo pipefail

ZONE="domain.local"
A1="10.10.10.11"
B1="10.10.10.21"
SSH="ssh -o BatchMode=yes -o ConnectTimeout=5"

echo "!! DISASTER FAILOVER — promoting B1 without waiting for A1 !!"
echo "Confirm A1 is actually down (not just slow):"
if $SSH root@"$A1" true 2>/dev/null; then
  echo "  [STOP] A1 IS reachable via SSH. This is not a disaster scenario --"
  echo "         use switchover-A-to-B.sh instead (it safely demotes A1 first)."
  exit 1
fi
echo "  [confirmed] A1 not reachable via SSH."

read -r -p "Type YES to promote B1 to master right now: " ans
[[ "$ans" == "YES" ]] || { echo "Aborted."; exit 1; }

echo
echo "### Promoting B1 (slave -> master) ###"
$SSH root@"$B1" bash -s <<EOF
set -e
knotc conf-begin
knotc conf-unset zone[${ZONE}].master
knotc conf-commit
knotc zone-status ${ZONE}
EOF

echo
echo "### Verifying ###"
sleep 2
dig @"$B1" "$ZONE" SOA +short
$SSH root@"$B1" "knotc zone-status ${ZONE}"

cat <<'NEXT'

B1 is now MASTER. Site B (B1/B2/B3) is authoritative.

NEXT STEPS:
  1. Update any external monitoring/pager to reflect Site B as active.
  2. If your NS delegation or clients prefer Site A by priority, update
     that routing/anycast/weighting now.
  3. When A1 physically/logically returns, run recover-A1-post-disaster.sh
     ON A1 BEFORE reconnecting it to the shared network — see
     04-RUNBOOK.md.
NEXT
