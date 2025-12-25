# polyvector

A tiny SQL-only PostgreSQL extension that adds a **dynamic embedding composite type** (`polyvec`) on top of **pgvector**.

It lets you store *one of several supported vector dimensions* in a single column, and provides search helpers that automatically route to the correct internal slot based on the query vector's dimension.

> In this repo, dimensions **3/4/5/6** are used as stand-ins for **384/768/1024/1536** to keep examples short and runnable. Replace with real dimensions in production forks or future versions.

## Why

`pgvector` requires fixed dimensions per `vector(N)` column. If you use multiple embedding models (or change models over time), you can end up with multiple columns or multiple tables.

`polyvec` provides a single column that can hold one of several supported dimensions while still allowing dimension-specific routing for querying.

## What you get

- `polyvec` composite type with:
  - `dims` and `slot` metadata
  - multiple fixed-size vector subfields (`v384`, `v768`, `v1024`, `v1536`)
- helpers:
  - `polyvec_set_embedding(polyvec, vector) -> polyvec`
  - `polyvec_get_embedding(polyvec) -> vector`
  - `polyvec_convert(vector) -> polyvec`
  - `polyvec_validate(polyvec) -> boolean`
- search functions:
  - `polyvec_search_l2(tbl regclass, poly_col text, q vector, k int=10)`
  - `polyvec_search_cosine(...)`
  - `polyvec_search_ip(...)`

All search functions return:

- `data` (JSONB of the full row with fully-qualified keys like `public.docs.title`)
- `distance` (float8)
- `slot` (which internal slot was used)

## Install

### Option A: Local install (copy files)
1. Find Postgres sharedir on the server:
   ```bash
   pg_config --sharedir
   ```
2. Copy:
   - `polyvector.control` → `<sharedir>/extension/`
   - `sql/polyvector--1.0.sql` → `<sharedir>/extension/`
3. In SQL:
   ```sql
   CREATE EXTENSION vector;
   CREATE EXTENSION polyvector;
   ```

### Option B: Install with PGXS (Makefile)
If you have `pg_config` available:

```bash
make install
```

Then in SQL:

```sql
CREATE EXTENSION vector;
CREATE EXTENSION polyvector;
```

### Docker note
If Postgres runs in a container, the files must be copied **into the container's** extension directory.

## Quickstart

Run the demo script:

```bash
psql -d <yourdb> -f examples/polyvec-sample.sql
```

Or call search directly:

```sql
SELECT *
FROM polyvec_search_l2(
  'public.docs'::regclass,
  'emb_b',
  '[0.01, 0.02, 0.03, 0.05]'::vector(4),
  5
);
```

## Indexing (recommended)

For real workloads, create **slot-specific** indexes matching the operator you use.

Example (HNSW, L2) for `docs.emb_b` when dims=4 maps to `v768`:

```sql
CREATE INDEX ON public.docs
USING hnsw (((emb_b).v768) vector_l2_ops);
```

Cosine:

```sql
CREATE INDEX ON public.docs
USING hnsw (((emb_b).v768) vector_cosine_ops);
```

Inner product:

```sql
CREATE INDEX ON public.docs
USING hnsw (((emb_b).v768) vector_ip_ops);
```

Repeat per slot (`v384`, `v768`, `v1024`, `v1536`) and per polyvec column as needed.

## Limitations / Notes

- Only one slot is intended to be populated per row (enforced by `polyvec_validate`).
- Query results are dimension-specific: a `vector(4)` query only searches rows whose `polyvec.dims = 4`.
- This is a SQL-only extension; no C code and no background workers.

## License

MIT. See `LICENSE`.
