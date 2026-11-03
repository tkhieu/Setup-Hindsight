#!/usr/bin/env bash
# Structural validation for a gzip'd pg_dump. Deliberately NOT a byte-size
# floor — a legitimately tiny database (a freshly-initialized Postgres
# cluster with no Hindsight schema applied yet, confirmed for real against
# the pinned pgvector/pg18 image: ~400 bytes gzipped) produces a genuinely
# small but COMPLETE dump.
#
# The pinned image's pg_dump is always 18.x, which always writes a
# \restrict <key> header and a matching \unrestrict <key> trailer (dump-
# locking feature, not data-dependent) — there is deliberately no fallback
# for a pre-18 dump format missing these: a bare "-- / marker / --" block
# with nothing else is also exactly what a 62-byte hand-crafted fake looks
# like, so without the restrict/unrestrict match there is nothing left
# that distinguishes a real dump from that. On top of the key match, the
# header must also show real pg_dump evidence (the "-- PostgreSQL database
# dump" banner and at least one "SET " statement) — a fake that only gets
# the \restrict/\unrestrict pair right still has to fake those too.
#
# Bounded memory regardless of dump size OR of how long any single line
# in it is (Hindsight stores attachments as BYTEA; pg_dump's escaped COPY
# format for one can legitimately be a single very long line): the header
# check reads only the first 64 KiB (`head -c`), the trailer check only
# the last 64 KiB (`tail -c`, which on a non-seekable pipe keeps a fixed-
# size trailing buffer and never grows with input size) — never the whole
# decompressed stream. `gzip -t` still validates the whole compressed
# stream's integrity, but that is gzip's own bounded streaming check, not
# ours.
assert_valid_pg_dump() {  # assert_valid_pg_dump <gzip-file>
  local f="$1" window=65536
  gzip -t "$f" 2>/dev/null || return 1

  # Header window. `head -c` stops reading once it has enough, which on a
  # dump bigger than $window makes the gunzip upstream of it exit via
  # SIGPIPE (expected, not a real failure — gzip -t above already proved
  # the compressed stream itself is intact) — `|| true` keeps that from
  # tripping this script's `set -e`.
  local head_blob header_key restrict_re
  head_blob="$(gunzip -c "$f" 2>/dev/null | head -c "$window")" || true

  # Checked with bash's own string/regex matching, not `printf | grep -q`:
  # grep -q can exit the moment it finds a match, before fully draining
  # printf's side of that pipe — printf then gets SIGPIPE, and under this
  # script's `set -o pipefail` that SIGPIPE (not a real failure) was
  # winning over grep's own success and failing the whole check. A real
  # dump's header is tens of KB (once it has a schema), comfortably over
  # the point where this was reproducible.
  case "$head_blob" in
    *'-- PostgreSQL database dump'*) ;;
    *) return 1 ;;
  esac
  # Leading synthetic newline so a SET/\restrict line at the very start of
  # the blob still matches "preceded by a newline" the same as one further
  # in — real dumps always have the banner first, so this is just to keep
  # the two cases from needing separate patterns.
  case $'\n'"$head_blob" in
    *$'\n''SET '*) ;;
    *) return 1 ;;
  esac
  restrict_re=$'\n''\\restrict ([A-Za-z0-9_-]+)'
  if [[ $'\n'"$head_blob" =~ $restrict_re ]]; then
    header_key="${BASH_REMATCH[1]}"
  else
    header_key=""
  fi
  [ -n "$header_key" ] || return 1

  # Trailer window, and the exact shape pg_dump 18.x writes:
  #   --
  #   -- PostgreSQL database dump complete
  #   --
  #   <blank>
  #   \unrestrict <key>
  # with <key> matching the header's \restrict <key>. `tail -c` reads the
  # whole stream (unlike `head -c`, it has to, to know where the end is)
  # but only ever retains the last $window bytes of it, so this stays
  # bounded no matter how large the dump or any one line in it is.
  gunzip -c "$f" 2>/dev/null | tail -c "$window" | awk -v key="$header_key" '
    { n++; buf[n] = $0 }
    END {
      last = n
      while (last > 0 && buf[last] == "") last--
      if (last < 5) { exit 1 }
      ok = (buf[last - 4] == "--") \
        && (buf[last - 3] == "-- PostgreSQL database dump complete") \
        && (buf[last - 2] == "--") \
        && (buf[last - 1] == "") \
        && (buf[last] == "\\unrestrict " key)
      exit (ok ? 0 : 1)
    }
  '
}
