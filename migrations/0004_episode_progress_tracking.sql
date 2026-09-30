-- =========================================================================
-- 004: episode-level progress + watched_at timestamp for statistics
-- =========================================================================

ALTER TABLE public.family_series
  ADD COLUMN IF NOT EXISTS total_seasons integer CHECK (total_seasons IS NULL OR total_seasons > 0),
  ADD COLUMN IF NOT EXISTS total_episodes integer CHECK (total_episodes IS NULL OR total_episodes > 0),
  ADD COLUMN IF NOT EXISTS episode_runtime_minutes integer CHECK (episode_runtime_minutes IS NULL OR episode_runtime_minutes > 0);

ALTER TABLE public.family_series_status
  ADD COLUMN IF NOT EXISTS watched_at timestamptz;

CREATE TABLE IF NOT EXISTS public.family_series_progress (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  series_id uuid NOT NULL REFERENCES public.family_series(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  current_season integer NOT NULL DEFAULT 1 CHECK (current_season > 0),
  current_episode integer NOT NULL DEFAULT 0 CHECK (current_episode >= 0),
  updated_at timestamptz NOT NULL DEFAULT NOW(),
  UNIQUE (series_id, user_id)
);

DROP TRIGGER IF EXISTS family_series_progress_touch_updated_at ON public.family_series_progress;
CREATE TRIGGER family_series_progress_touch_updated_at
  BEFORE UPDATE ON public.family_series_progress
  FOR EACH ROW
  EXECUTE FUNCTION public.touch_updated_at();

ALTER TABLE public.family_series_progress ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.family_series_progress FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS family_series_progress_select_member ON public.family_series_progress;
CREATE POLICY family_series_progress_select_member
  ON public.family_series_progress
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.family_series series
      WHERE series.id = family_series_progress.series_id
        AND public.is_family_member(series.family_id)
    )
  );

DROP POLICY IF EXISTS family_series_progress_upsert_own ON public.family_series_progress;
CREATE POLICY family_series_progress_upsert_own
  ON public.family_series_progress
  FOR INSERT
  WITH CHECK (
    user_id = public.current_user_id()
    AND EXISTS (
      SELECT 1 FROM public.family_series series
      WHERE series.id = family_series_progress.series_id
        AND public.is_family_member(series.family_id)
    )
  );

DROP POLICY IF EXISTS family_series_progress_update_own ON public.family_series_progress;
CREATE POLICY family_series_progress_update_own
  ON public.family_series_progress
  FOR UPDATE
  USING (user_id = public.current_user_id())
  WITH CHECK (user_id = public.current_user_id());

DROP POLICY IF EXISTS family_series_progress_delete_own ON public.family_series_progress;
CREATE POLICY family_series_progress_delete_own
  ON public.family_series_progress
  FOR DELETE
  USING (user_id = public.current_user_id());
