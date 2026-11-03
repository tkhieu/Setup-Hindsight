#!/usr/bin/env bash
# Structural validation for a gzip'd pg_dump. Deliberately NOT a byte-size
# floor — a legitimately tiny database (a freshly-initialized Postgres
# cluster with no Hindsight schema applied yet, confirmed for real against
# the pinned pgvector/pg18 image: ~400 bytes gzipped) produces a genuinely
# small but COMPLETE dump.
#
# This checks the EXACT trailer pg_dump 18.x (the pinned image's pg_dump;
# confirmed against a real dump) writes, not just "the marker string
# appears somewhere near the end" — that weaker check let a truncated
# trailer, or a marker followed by appended garbage, both pass. A real
# dump from this image ends:
#
#   --
#   -- PostgreSQL database dump complete
#   --
#   <blank>
#   \unrestrict <key>
#
# where <key> matches a `\restrict <key>` line pg_dump writes near the
# top of the same dump (pg18's dump-locking mechanism — confirmed: the two
# keys are byte-identical in a real dump). Checking that match, not just
# the marker's presence, catches a dump whose header and trailer were
# spliced from two different runs, which a bare substring grep cannot.
# Older pg_dump output (no \restrict/\unrestrict at all) falls back to
# requiring the marker as the literal last non-blank line.
#
# Streaming, bounded memory regardless of dump size: only the last few
# lines are ever held (a small fixed-size ring buffer), never the whole
# decompressed dump.
assert_valid_pg_dump() {  # assert_valid_pg_dump <gzip-file>
  local f="$1"
  gzip -t "$f" 2>/dev/null || return 1
  gunzip -c "$f" 2>/dev/null | awk '
    BEGIN { K = 8; n = 0; header_key = "" }
    {
      if (header_key == "" && NR <= 20 && $0 ~ /^\\restrict /) {
        split($0, parts, " ")
        header_key = parts[2]
      }
      n++
      buf[n % K] = $0
    }
    END {
      if (n == 0) { exit 1 }
      limit = (n < K) ? n : K
      for (i = 0; i < limit; i++) {
        idx = n - limit + 1 + i
        arr[i + 1] = buf[idx % K]
      }
      last = limit
      while (last > 0 && arr[last] == "") last--
      if (header_key != "") {
        if (last < 5) { exit 1 }
        ok = (arr[last - 4] == "--") \
          && (arr[last - 3] == "-- PostgreSQL database dump complete") \
          && (arr[last - 2] == "--") \
          && (arr[last - 1] == "") \
          && (arr[last] == "\\unrestrict " header_key)
        exit (ok ? 0 : 1)
      } else {
        # No \restrict header (older pg_dump, no dump-locking feature): the
        # fixed "--" comment-delimiter wrapper around the marker is still
        # always emitted (it is not part of the restrict/unrestrict feature), so
        # the trailer is the same 3-line "-- / marker / --" block with
        # nothing — not even a blank line — after the closing "--".
        if (last < 3) { exit 1 }
        ok = (arr[last - 2] == "--") \
          && (arr[last - 1] == "-- PostgreSQL database dump complete") \
          && (arr[last] == "--")
        exit (ok ? 0 : 1)
      }
    }
  '
}
