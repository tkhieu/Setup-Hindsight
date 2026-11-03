#!/bin/sh
# bin/lib/dump.sh's assert_valid_pg_dump must check the EXACT pg_dump
# trailer, not just "the completion marker appears somewhere near the
# end" — that weaker check let a truncated trailer, a marker followed by
# garbage, and a header/footer restrict-key mismatch all pass. Fixtures
# below mirror a REAL dump captured from the pinned pgvector/pg18 image
# (docker run pgvector/pgvector:pg18 ...; pg_dump -U hindsight_user
# hindsight_db), not synthetic shapes guessed at.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SS="$(cd "$HERE/.." && pwd)/server-setup"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

KEY="ypB7Xww3Pc9tYPUbJQGJAghsVyinexUR8gVrqzR5nTrfSytemGzC7IFuDUfClKm"
OTHERKEY="DIFFERENTKEY0000000000000000000000000000000000000000000000000"

# A real, complete pg18 dump (header \restrict line + matching \unrestrict
# trailer, byte-for-byte shape as captured for real).
make_valid() {
  cat <<SQL
--
-- PostgreSQL database dump
--

\\restrict $KEY

-- Dumped from database version 18.6 (Debian 18.6-1.pgdg12+2)
-- Dumped by pg_dump version 18.6 (Debian 18.6-1.pgdg12+2)

SET statement_timeout = 0;
SET client_encoding = 'UTF8';
SET row_security = off;

--
-- PostgreSQL database dump complete
--

\\unrestrict $KEY
SQL
}

assert_case() {  # assert_case <label> <sql-file> <bash -c 'assert_valid_pg_dump ...' expected 0|1>
  label="$1"; sqlfile="$2"; expect="$3"
  gzip -c "$sqlfile" > "$sqlfile.gz"
  if bash -c ". '$SS/bin/lib/dump.sh'; assert_valid_pg_dump '$sqlfile.gz'"; then got=0; else got=1; fi
  if [ "$got" != "$expect" ]; then
    echo "FAIL: $label (expected $expect, got $got)"
    exit 1
  fi
  echo "ok - $label"
}

# 1. valid pg18 dump
make_valid > "$TMP/valid.sql"
assert_case "valid pg18 dump" "$TMP/valid.sql" 0

# 2. truncated trailer: cut off before the \unrestrict line entirely
make_valid | sed '/^\\unrestrict/d' > "$TMP/truncated.sql"
assert_case "truncated trailer (missing unrestrict)" "$TMP/truncated.sql" 1

# 3. marker present, but followed by appended garbage (not part of the dump)
{ make_valid; printf 'GARBAGE NOT PART OF ANY REAL DUMP\n'; } > "$TMP/garbage.sql"
assert_case "marker followed by garbage" "$TMP/garbage.sql" 1

# 4. header \restrict key does not match the footer \unrestrict key
make_valid | sed "s/\\\\unrestrict $KEY/\\\\unrestrict $OTHERKEY/" > "$TMP/mismatch.sql"
assert_case "restrict/unrestrict key mismatch" "$TMP/mismatch.sql" 1

# 5. gzip-valid but not a pg_dump at all
printf 'just some random text, not sql at all\n' > "$TMP/notsql.sql"
assert_case "gzip-valid non-SQL garbage" "$TMP/notsql.sql" 1

# 6. older pg_dump format with no \restrict/\unrestrict at all — the
# marker's own "-- / marker / --" wrapper, with nothing after it, is the
# fallback shape that must still pass.
cat > "$TMP/oldformat.sql" <<'SQL'
--
-- PostgreSQL database dump
--

SET statement_timeout = 0;
SET client_encoding = 'UTF8';

--
-- PostgreSQL database dump complete
--
SQL
assert_case "old pg_dump format (no restrict/unrestrict)" "$TMP/oldformat.sql" 0

echo ok
