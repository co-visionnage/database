-- =========================================================================
-- 009: distinguish series vs. movies
--
-- Movies don't have seasons/episodes, so total_seasons/total_episodes stay
-- meaningless for them; the app hides the episode-progress UI for movies
-- based on this column instead of inferring it from those fields.
-- =========================================================================

ALTER TABLE public.family_series
  ADD COLUMN IF NOT EXISTS media_type varchar(10) NOT NULL DEFAULT 'series'
    CHECK (media_type IN ('series', 'movie'));
