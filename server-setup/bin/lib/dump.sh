#!/usr/bin/env bash
# Structural validation for a gzip'd pg_dump. This is the completeness
# gate — deliberately NOT a byte-size floor. A legitimately tiny database
# (a freshly-initialized Postgres cluster with no Hindsight schema applied
# yet — e.g. a cold restore's own pre-restore safety backup, taken before
# anything has ever run migrations — or an instance nobody has retained
# into) produces a genuinely small but COMPLETE dump; a real one measured
# well under a 2048-byte floor that an earlier version of this check used,
# which made exactly that cold-restore case fail. pg_dump always writes
# "-- PostgreSQL database dump complete" as its last line when (and only
# when) it finished successfully — a truncated/corrupt dump never has it,
# regardless of size — so this is a strictly better completeness signal
# than any size threshold.
assert_valid_pg_dump() {  # assert_valid_pg_dump <gzip-file>
  local f="$1"
  gzip -t "$f" 2>/dev/null || return 1
  gunzip -c "$f" 2>/dev/null | tail -c 4096 | grep -q -- '-- PostgreSQL database dump complete' || return 1
}
