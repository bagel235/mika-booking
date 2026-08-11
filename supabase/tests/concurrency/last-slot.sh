#!/usr/bin/env bash
set -euo pipefail
: "${DATABASE_URL:?Set DATABASE_URL}"
DATE=2031-01-06
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c "select * from create_booking_hold('CUSTOMER_WEB','seed','seed','$DATE','15:00',1,'SINGLE',0);" >/dev/null
work_dir="$(mktemp -d)"; trap 'rm -rf "$work_dir"' EXIT
psql "$DATABASE_URL" -c "select * from create_booking_hold('CUSTOMER_WEB','race-a','a','$DATE','15:00',1,'SINGLE',0);" >"$work_dir/a" 2>&1 & a=$!
psql "$DATABASE_URL" -c "select * from create_booking_hold('STAFF_MANUAL','race-b','b','$DATE','15:00',1,'DOUBLE',0);" >"$work_dir/b" 2>&1 & b=$!
set +e; wait "$a"; ar=$?; wait "$b"; br=$?; set -e
if { [ "$ar" -eq 0 ] && [ "$br" -ne 0 ]; } || { [ "$ar" -ne 0 ] && [ "$br" -eq 0 ]; }; then echo "PASS: exactly one concurrent request won"; else cat "$work_dir/a" "$work_dir/b"; exit 1; fi
