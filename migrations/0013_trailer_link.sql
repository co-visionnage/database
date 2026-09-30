-- =========================================================================
-- 013: trailer link
-- =========================================================================

ALTER TABLE public.family_series
  ADD COLUMN IF NOT EXISTS trailer_url text;
