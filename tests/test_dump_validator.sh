#!/bin/sh
# bin/lib/dump.sh's assert_valid_pg_dump must check the EXACT pg_dump
# trailer, not just "the completion marker appears somewhere near the
# end" — that weaker check let a truncated trailer, a marker followed by
# garbage, a header/footer restrict-key mismatch, AND a 62-byte hand-
# crafted fake with just the marker's own "-- / marker / --" wrapper all
# pass (the pinned image's pg_dump is always 18.x, which always writes
# \restrict/\unrestrict — there is no fallback for dumps missing them).
# It must also stay bounded in memory regardless of how long any single
# line in the dump is (realistic: a BYTEA attachment's escaped COPY row
# can be one very long line). Fixtures below mirror a REAL dump captured
# from the pinned pgvector/pg18 image (docker run pgvector/pgvector:pg18
# ...; pg_dump -U hindsight_user hindsight_db), not synthetic shapes
# guessed at.
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

# 6. A 62-byte hand-crafted fake with just "-- / marker / --" and nothing
# else — no \restrict/\unrestrict, no banner, no SET statement. The
# pinned image's pg_dump is always 18.x (always writes restrict/
# unrestrict), so there is no fallback for this shape anymore: it must be
# rejected, not accepted as "an older pg_dump format".
cat > "$TMP/fake62.sql" <<'SQL'
--
-- PostgreSQL database dump complete
--
SQL
assert_case "62-byte hand-crafted fake (no restrict/unrestrict)" "$TMP/fake62.sql" 1

# 7. A single ~32 MiB line (realistic: Hindsight stores attachments as
# BYTEA; pg_dump's escaped COPY format for one can be one very long line)
# must not blow up memory, and must still complete (and still be accepted
# — it is a structurally valid dump, just with one huge data line in the
# middle, nothing to do with validity).
{
  printf -- '--\n-- PostgreSQL database dump\n--\n\n\\restrict %s\n\nSET statement_timeout = 0;\nSET client_encoding = UTF8;\n\n' "$KEY"
  printf 'COPY huge_table (data) FROM stdin;\n'
  head -c 33554432 /dev/zero | tr '\0' 'A'  # exactly 32 MiB, one line, no embedded newlines
  printf '\n\\.\n\n--\n-- PostgreSQL database dump complete\n--\n\n\\unrestrict %s\n' "$KEY"
} > "$TMP/hugeline.sql"
wc -c "$TMP/hugeline.sql"
gzip -c "$TMP/hugeline.sql" > "$TMP/hugeline.sql.gz"
if command -v /usr/bin/time >/dev/null 2>&1; then
  /usr/bin/time -v bash -c ". '$SS/bin/lib/dump.sh'; assert_valid_pg_dump '$TMP/hugeline.sql.gz'" 2>"$TMP/time.out" \
    && got=0 || got=1
  grep -i "Maximum resident set size" "$TMP/time.out" || true
else
  if bash -c ". '$SS/bin/lib/dump.sh'; assert_valid_pg_dump '$TMP/hugeline.sql.gz'"; then got=0; else got=1; fi
fi
if [ "$got" != 0 ]; then
  echo "FAIL: 32 MiB single-line dump (expected 0, got $got)"
  exit 1
fi
echo "ok - 32 MiB single-line dump completes and is accepted"

echo ok
