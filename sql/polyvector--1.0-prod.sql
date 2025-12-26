-- polyvector--1.0.sql
-- Dynamic polyvector composite type on top of pgvector.
--
-- This extension is SQL-only and depends on pgvector.
-- The .control file includes: requires = 'vector'

-- ============================================================
-- 1) Dynamic embedding composite type: polyvec
-- ============================================================

CREATE TYPE polyvec AS (
  dims  int,
  slot  text,
  v384  vector(384),
  v768  vector(768),
  v1024 vector(1024),
  v1536 vector(1536)
);

-- ============================================================
-- 2) polyvec_validate: enforce "exactly one slot is set"
-- ============================================================

CREATE OR REPLACE FUNCTION polyvec_validate(e polyvec)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  nn int;
BEGIN
  IF e IS NULL THEN
    RETURN true;
  END IF;

  IF e.dims IS NULL OR e.dims NOT IN (384, 768, 1024, 1536) THEN
    RETURN false;
  END IF;

  nn :=
    (e.v384  IS NOT NULL)::int +
    (e.v768  IS NOT NULL)::int +
    (e.v1024 IS NOT NULL)::int +
    (e.v1536 IS NOT NULL)::int;

  IF nn <> 1 THEN
    RETURN false;
  END IF;

  IF e.dims = 384 THEN RETURN e.v384  IS NOT NULL AND e.slot = 'v384';  END IF;
  IF e.dims = 768 THEN RETURN e.v768  IS NOT NULL AND e.slot = 'v768';  END IF;
  IF e.dims = 1024 THEN RETURN e.v1024 IS NOT NULL AND e.slot = 'v1024'; END IF;
  IF e.dims = 1536 THEN RETURN e.v1536 IS NOT NULL AND e.slot = 'v1536'; END IF;

  RETURN false;
END;
$$;

-- ============================================================
-- 3) polyvec_set_embedding: write router (NULL-safe)
-- ============================================================

CREATE OR REPLACE FUNCTION polyvec_set_embedding(e polyvec, v vector)
RETURNS polyvec
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  d int := vector_dims(v);
BEGIN
  -- Initialize if NULL (so you can store DEFAULT NULL in table)
  IF e IS NULL THEN
    e := ROW(NULL, NULL, NULL, NULL, NULL, NULL)::polyvec;
  END IF;

  e.dims := d;

  IF d = 384 THEN
    e.slot := 'v384';
    e.v384 := v;
    e.v768 := NULL; e.v1024 := NULL; e.v1536 := NULL;

  ELSIF d = 768 THEN
    e.slot := 'v768';
    e.v768 := v;
    e.v384 := NULL; e.v1024 := NULL; e.v1536 := NULL;

  ELSIF d = 1024 THEN
    e.slot := 'v1024';
    e.v1024 := v;
    e.v384 := NULL; e.v768 := NULL; e.v1536 := NULL;

  ELSIF d = 1536 THEN
    e.slot := 'v1536';
    e.v1536 := v;
    e.v384 := NULL; e.v768 := NULL; e.v1024 := NULL;

  ELSE
    RAISE EXCEPTION 'Unsupported dims: %', d;
  END IF;

  RETURN e;
END;
$$;

-- ============================================================
-- 4) polyvec_get_embedding: read router
-- ============================================================

CREATE OR REPLACE FUNCTION polyvec_get_embedding(e polyvec)
RETURNS vector
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  IF e IS NULL THEN
    RETURN NULL;
  END IF;

  IF e.dims = 384 THEN RETURN e.v384;
  ELSIF e.dims = 768 THEN RETURN e.v768;
  ELSIF e.dims = 1024 THEN RETURN e.v1024;
  ELSIF e.dims = 1536 THEN RETURN e.v1536;
  ELSE RAISE EXCEPTION 'Unsupported dims: %', e.dims;
  END IF;
END;
$$;

-- ============================================================
-- 5) polyvec_convert: handy wrapper for inserts
-- ============================================================

CREATE OR REPLACE FUNCTION polyvec_convert(vec vector)
RETURNS polyvec
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  RETURN polyvec_set_embedding(NULL::polyvec, vec);
END;
$$;

-- ============================================================
-- 6) Internal search implementation (single code path)
--    op is allowlisted to keep this safe.
-- ============================================================

CREATE OR REPLACE FUNCTION polyvec__search_impl(
  tbl      regclass,
  poly_col text,
  q        vector,
  k        int,
  op       text         -- '<->' | '<=>' | '<#>'
)
RETURNS TABLE(data jsonb, distance float8, slot text)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  d int := vector_dims(q);
  slot_field text;
  slot_label text;

  cols_kv text;   -- "'schema.table.col', t.col, ..."
  sql text;
BEGIN
  -- Defensive allowlist for the operator
  IF op NOT IN ('<->', '<=>', '<#>') THEN
    RAISE EXCEPTION 'Unsupported operator: %', op;
  END IF;

  -- Clear error if the caller passes a wrong column name
  IF NOT EXISTS (
    SELECT 1
    FROM pg_attribute
    WHERE attrelid = tbl
      AND attname = poly_col
      AND attnum > 0
      AND NOT attisdropped
  ) THEN
    RAISE EXCEPTION 'Column "%" does not exist on table %', poly_col, tbl::text;
  END IF;

  -- Map query dims -> slot field name inside polyvec
  IF d = 384 THEN slot_field := 'v384';  slot_label := poly_col || '.v384';
  ELSIF d = 768 THEN slot_field := 'v768';  slot_label := poly_col || '.v768';
  ELSIF d = 1024 THEN slot_field := 'v1024'; slot_label := poly_col || '.v1024';
  ELSIF d = 1536 THEN slot_field := 'v1536'; slot_label := poly_col || '.v1536';
  ELSE
    RAISE EXCEPTION 'Unsupported dims: %', d;
  END IF;

  -- Build JSONB key/value args with fully-qualified keys: "<schema.table>.<column>"
  SELECT string_agg(
           format('%L, t.%I', (tbl::text || '.' || a.attname), a.attname),
           ', '
         )
  INTO cols_kv
  FROM pg_attribute a
  WHERE a.attrelid = tbl
    AND a.attnum > 0
    AND NOT a.attisdropped;

  IF cols_kv IS NULL THEN
    RAISE EXCEPTION 'Could not enumerate columns for table %', tbl::text;
  END IF;

  sql := format($SQL$
    SELECT
      jsonb_build_object(%1$s) AS data,
      ((t.%2$I).%3$I %4$s $1)::float8 AS distance,
      %5$L::text AS slot
    FROM %6$s t
    WHERE
      (t.%2$I).dims = %7$s
      AND (t.%2$I).%3$I IS NOT NULL
    ORDER BY (t.%2$I).%3$I %4$s $1
    LIMIT $2
  $SQL$,
    cols_kv,
    poly_col,
    slot_field,
    op,
    slot_label,
    tbl,
    d
  );

  RETURN QUERY EXECUTE sql USING q, k;
END;
$$;

-- ============================================================
-- 7) Public search wrappers (user-friendly)
-- ============================================================

CREATE OR REPLACE FUNCTION polyvec_search_l2(
  tbl      regclass,
  poly_col text,
  q        vector,
  k        int DEFAULT 10
)
RETURNS TABLE(data jsonb, distance float8, slot text)
LANGUAGE sql
STABLE
AS $$
  SELECT * FROM polyvec__search_impl(tbl, poly_col, q, k, '<->');
$$;

CREATE OR REPLACE FUNCTION polyvec_search_cosine(
  tbl      regclass,
  poly_col text,
  q        vector,
  k        int DEFAULT 10
)
RETURNS TABLE(data jsonb, distance float8, slot text)
LANGUAGE sql
STABLE
AS $$
  SELECT * FROM polyvec__search_impl(tbl, poly_col, q, k, '<=>');
$$;

CREATE OR REPLACE FUNCTION polyvec_search_ip(
  tbl      regclass,
  poly_col text,
  q        vector,
  k        int DEFAULT 10
)
RETURNS TABLE(data jsonb, distance float8, slot text)
LANGUAGE sql
STABLE
AS $$
  SELECT * FROM polyvec__search_impl(tbl, poly_col, q, k, '<#>');
$$;
