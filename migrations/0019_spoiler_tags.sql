-- =========================================================================
-- 017: optional spoiler tag on series comments
--
-- A comment can optionally declare which season/episode it discusses;
-- family_series_progress already tracks each viewer's own current
-- season/episode, so the client can hide/blur comments tagged further
-- ahead than the viewer has gotten. episode is only meaningful alongside
-- season, hence the CHECK.
-- =========================================================================

ALTER TABLE public.family_series_comments
  ADD COLUMN IF NOT EXISTS spoiler_season integer CHECK (spoiler_season IS NULL OR spoiler_season > 0),
  ADD COLUMN IF NOT EXISTS spoiler_episode integer CHECK (spoiler_episode IS NULL OR spoiler_episode >= 0);

ALTER TABLE public.family_series_comments
  DROP CONSTRAINT IF EXISTS family_series_comments_spoiler_episode_requires_season;
ALTER TABLE public.family_series_comments
  ADD CONSTRAINT family_series_comments_spoiler_episode_requires_season
    CHECK (spoiler_episode IS NULL OR spoiler_season IS NOT NULL);
