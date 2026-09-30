-- =========================================================================
-- 011: "you haven't continued X in a while" nudges
--
-- Same story as the season-tracking cron: this runs with no logged-in
-- user, so it needs its own narrowly-scoped SECURITY DEFINER functions.
-- last_reminded_at throttles repeat nudges for the same series/user pair
-- to once a week, regardless of how often the cron job itself runs.
-- =========================================================================

ALTER TABLE public.family_series_progress
  ADD COLUMN IF NOT EXISTS last_reminded_at timestamptz;

CREATE OR REPLACE FUNCTION public.get_stale_progress(days_threshold integer)
RETURNS TABLE (
  series_id uuid,
  user_id uuid,
  title text,
  current_season integer,
  current_episode integer
)
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
  SELECT
    progress.series_id,
    progress.user_id,
    series.title,
    progress.current_season,
    progress.current_episode
  FROM public.family_series_progress progress
  JOIN public.family_series series ON series.id = progress.series_id
  JOIN public.family_series_status status
    ON status.series_id = progress.series_id
   AND status.user_id = progress.user_id
  WHERE status.status = 'to-watch'
    AND progress.current_episode > 0
    AND progress.updated_at < NOW() - (days_threshold || ' days')::interval
    AND (
      progress.last_reminded_at IS NULL
      OR progress.last_reminded_at < NOW() - INTERVAL '7 days'
    );
$$;

CREATE OR REPLACE FUNCTION public.mark_progress_reminded(
  target_series_id uuid,
  target_user_id uuid
)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
AS $$
  UPDATE public.family_series_progress
  SET last_reminded_at = NOW()
  WHERE series_id = target_series_id
    AND user_id = target_user_id;
$$;

CREATE OR REPLACE FUNCTION public.get_user_push_subscriptions_system(
  target_user_id uuid
)
RETURNS TABLE (endpoint text, p256dh text, auth text)
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
  SELECT endpoint, p256dh, auth
  FROM public.push_subscriptions
  WHERE user_id = target_user_id;
$$;

CREATE OR REPLACE FUNCTION public.get_user_email_system(target_user_id uuid)
RETURNS text
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
  SELECT email FROM public.profiles WHERE id = target_user_id;
$$;
