-- =========================================================================
-- 017: next-episode air date calendar
--
-- Distinct from migration 010 (which only bumps total_seasons/
-- total_episodes when a new season appears): this stores the actual next
-- air date/label (e.g. "S3E5") for series whose external_id is already an
-- IMDb id (the omdb and imdb-csv import sources), resolved via TMDB's
-- find-by-external-id + tv-details endpoints. get_series_for_episode_check
-- and update_series_next_episode mirror the SECURITY DEFINER shape of
-- their season-tracking counterparts for the same reason: the scheduled
-- check runs with no logged-in user.
-- =========================================================================

ALTER TABLE public.family_series
  ADD COLUMN IF NOT EXISTS next_episode_air_date date,
  ADD COLUMN IF NOT EXISTS next_episode_label varchar(20);

CREATE OR REPLACE FUNCTION public.get_series_for_episode_check()
RETURNS TABLE (
  id uuid,
  family_id uuid,
  title text,
  external_source varchar(20),
  external_id text
)
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
  SELECT id, family_id, title, external_source, external_id
  FROM public.family_series
  WHERE external_id IS NOT NULL
    AND external_source IN ('omdb', 'imdb-csv')
    AND media_type = 'series';
$$;

CREATE OR REPLACE FUNCTION public.update_series_next_episode(
  target_series_id uuid,
  new_air_date date,
  new_label text
)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
AS $$
  UPDATE public.family_series
  SET next_episode_air_date = new_air_date,
      next_episode_label = new_label
  WHERE id = target_series_id;
$$;
