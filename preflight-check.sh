#!/usr/bin/env bash
# preflight-check.sh
# Run from an admin/jump host with SSH key access to A1 and B1.
# Verifies both heads are reachable and reports SOA serial parity before
# you attempt a PLANNED switchover or failback. Does NOT change anything.

set -euo pipefail

ZONE="domain.local"
A1="10.10.10.11"
B1="10.10.10.21"
SSH="ssh -o BatchMode=yes -o ConnectTimeout=5"

echo "== Knot DNS preflight check: ${ZONE} =="
echo

fail=0

get_serial() {
  local host="$1"
  dig @"$host" "$ZONE" SOA +short 2>/dev/null | awk '{print $3}'
}

get_role() {
  local host="$1"
  $SSH root@"$host" "knotc zone-status ${ZONE}" 2>/dev/null \
    | grep -oE 'role: (master|slave)' | awk '{print $2}'
}

echo "-- Reachability --"
for h in "$A1" "$B1"; do
  if $SSH root@"$h" true 2>/dev/null; then
    echo "  [OK]   $h SSH reachable"
  else
    echo "  [FAIL] $h SSH NOT reachable"
    fail=1
  fi
done

echo
echo "-- DNS answer + role --"
A1_SERIAL=$(get_serial "$A1" || echo "NOENTRY")
B1_SERIAL=$(get_serial "$B1" || echo "NOENTRY")
A1_ROLE=$($SSH root@"$A1" true 2>/dev/null && get_role "$A1" || echo "UNKNOWN")
B1_ROLE=$($SSH root@"$B1" true 2>/dev/null && get_role "$B1" || echo "UNKNOWN")

echo "  A1 (${A1}): serial=${A1_SERIAL}  role=${A1_ROLE}"
echo "  B1 (${B1}): serial=${B1_SERIAL}  role=${B1_ROLE}"

echo
echo "-- Split-brain sanity --"
if [[ "$A1_ROLE" == "master" && "$B1_ROLE" == "master" ]]; then
  echo "  [CRITICAL] BOTH A1 and B1 report role=master. SPLIT BRAIN IS ALREADY"
  echo "             ACTIVE. Do not run any promote/demote script — resolve"
  echo "             manually first (see 04-RUNBOOK.md 'Recovering from an"
  echo "             actual split-brain')."
  fail=1
elif [[ "$A1_ROLE" == "slave" && "$B1_ROLE" == "slave" ]]; then
  echo "  [WARN] Neither node is currently master. Zone is read-only fleet-wide."
  echo "         This is safe but no updates can be accepted until one is promoted."
else
  echo "  [OK] Exactly one master detected."
fi

echo
echo "-- Serial parity --"
if [[ "$A1_SERIAL" == "$B1_SERIAL" && "$A1_SERIAL" != "NOENTRY" ]]; then
  echo "  [OK] Serials match ($A1_SERIAL). Safe to switch either direction."
else
  echo "  [WARN] Serials differ (A1=$A1_SERIAL, B1=$B1_SERIAL)."
  echo "         The node that is currently SLAVE should be force-refreshed"
  echo "         and rechecked before you promote it. See step 2 of the"
  echo "         switchover scripts (they do this automatically)."
fi

echo
if [[ "$fail" -eq 1 ]]; then
  echo "RESULT: NOT SAFE to proceed automatically. Investigate above."
  exit 1
else
  echo "RESULT: Checks passed."
  exit 0
fi
