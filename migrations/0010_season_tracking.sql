-- =========================================================================
-- 010: track new-season releases for series imported from an external
-- catalog (Kinopoisk/OMDb).
--
-- The scheduled check runs without a logged-in user, so the ordinary RLS
-- path (current_user_id() driven) can't see or touch any family's rows.
-- These three functions are SECURITY DEFINER with no caller check — they
-- are only ever meant to be called from the trusted /api/cron route, which
-- is itself gated by a server-side secret before it touches the database.
-- They must never be exposed to arbitrary client-supplied family ids.
-- =========================================================================

ALTER TABLE public.family_series
  ADD COLUMN IF NOT EXISTS external_source varchar(20),
  ADD COLUMN IF NOT EXISTS external_id text;

CREATE OR REPLACE FUNCTION public.get_series_with_external_ids()
RETURNS TABLE (
  id uuid,
  family_id uuid,
  title text,
  external_source varchar(20),
  external_id text,
  total_seasons integer,
  total_episodes integer
)
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
  SELECT id, family_id, title, external_source, external_id, total_seasons, total_episodes
  FROM public.family_series
  WHERE external_id IS NOT NULL
    AND external_source IS NOT NULL
    AND media_type = 'series';
$$;

CREATE OR REPLACE FUNCTION public.update_series_season_tracking(
  target_series_id uuid,
  new_total_seasons integer,
  new_total_episodes integer
)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
AS $$
  UPDATE public.family_series
  SET total_seasons = new_total_seasons,
      total_episodes = COALESCE(new_total_episodes, total_episodes)
  WHERE id = target_series_id;
$$;

CREATE OR REPLACE FUNCTION public.get_family_push_subscriptions_system(
  target_family_id uuid
)
RETURNS TABLE (endpoint text, p256dh text, auth text)
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
  SELECT sub.endpoint, sub.p256dh, sub.auth
  FROM public.push_subscriptions sub
  JOIN public.family_members member ON member.user_id = sub.user_id
  WHERE member.family_id = target_family_id;
$$;

CREATE OR REPLACE FUNCTION public.get_family_member_emails_system(
  target_family_id uuid
)
RETURNS TABLE (email text)
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
  SELECT profile.email
  FROM public.family_members member
  JOIN public.profiles profile ON profile.id = member.user_id
  WHERE member.family_id = target_family_id;
$$;
