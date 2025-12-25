-- examples/polyvec-sample.sql
-- End-to-end demo for polyvector extension.

-- 0) Prereqs
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS polyvector;

-- 1) Demo table: two dynamic embedding columns + one normal vector column
DROP TABLE IF EXISTS public.docs;
CREATE TABLE public.docs (
  id       bigserial PRIMARY KEY,
  title    text NOT NULL,
  emb_a    polyvec,
  emb_b    polyvec,
  emb_std  vector(4)   -- normal pgvector column (fixed dims)
);

-- 2) Insert demo rows
INSERT INTO public.docs (title, emb_a, emb_b, emb_std) VALUES
  (
    'Doc A',
    polyvec_convert('[0.5, 0.4, 0.3, 0.2, 0.1]'::vector(5)),          -- dims=5 -> v1024 slot (demo dims)
    polyvec_convert('[0.01, 0.02, 0.03, 0.04]'::vector(4)),           -- dims=4 -> v768 slot
    '[0.01, 0.02, 0.03, 0.04]'::vector(4)
  ),
  (
    'Doc B',
    polyvec_convert('[0.9, 0.8, 0.7, 0.6, 0.5]'::vector(5)),          -- dims=5 -> v1024 slot
    polyvec_convert('[0.1, 0.2, 0.3, 0.4, 0.5, 0.6]'::vector(6)),     -- dims=6 -> v1536 slot
    '[0.02, 0.01, 0.03, 0.05]'::vector(4)
  );

-- 3) Update: replace Doc A emb_b with a new dims=4 vector
UPDATE public.docs
SET emb_b = polyvec_set_embedding(emb_b, '[0.01, 0.02, 0.03, 0.05]'::vector(4))
WHERE title = 'Doc A';

-- 4) Inspect stored slots
SELECT
  id, title,
  (emb_a).dims AS a_dims, (emb_a).slot AS a_slot,
  (emb_b).dims AS b_dims, (emb_b).slot AS b_slot
FROM public.docs
ORDER BY id;

-- 5) Search examples (dimension-specific)
-- Query emb_b using dims=4 => will search v768 slot
SELECT *
FROM polyvec_search_l2('public.docs'::regclass, 'emb_b', '[0.01, 0.02, 0.03, 0.05]'::vector(4), 5);

-- Show id/title easily
SELECT
  (data->>'public.docs.id')::bigint AS id,
  data->>'public.docs.title'        AS title,
  distance,
  slot
FROM polyvec_search_l2('public.docs'::regclass, 'emb_b', '[0.01, 0.02, 0.03, 0.05]'::vector(4), 5);

-- Cosine variant
SELECT *
FROM polyvec_search_cosine('public.docs'::regclass, 'emb_b', '[0.01, 0.02, 0.03, 0.05]'::vector(4), 5);

-- Inner product variant
SELECT *
FROM polyvec_search_ip('public.docs'::regclass, 'emb_b', '[0.01, 0.02, 0.03, 0.05]'::vector(4), 5);
