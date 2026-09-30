-- =========================================================================
-- 015: rate limiting for login/registration and the external import proxy
--
-- Login/registration is reachable before a session exists, and the import
-- endpoint forwards to quota-limited third-party APIs (Kinopoisk/OMDb), so
-- neither can be gated by app.current_user_id/RLS the way the rest of the
-- schema is. This is a plain fixed-window counter keyed by an arbitrary
-- string ("login:email:<email>", "login:ip:<ip>", "import:ip:<ip>", ...);
-- check_rate_limit is SECURITY DEFINER because a bucket is shared across
-- unrelated callers and isn't scoped to any one user's RLS context.
-- =========================================================================

CREATE TABLE IF NOT EXISTS public.rate_limit_buckets (
  bucket_key text PRIMARY KEY,
  attempt_count integer NOT NULL DEFAULT 0,
  window_started_at timestamptz NOT NULL DEFAULT NOW()
);

ALTER TABLE public.rate_limit_buckets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rate_limit_buckets FORCE ROW LEVEL SECURITY;
-- No policies: every access goes through check_rate_limit below.

CREATE OR REPLACE FUNCTION public.check_rate_limit(
  p_bucket_key text,
  p_max_attempts integer,
  p_window_seconds integer
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  bucket public.rate_limit_buckets;
BEGIN
  INSERT INTO public.rate_limit_buckets (bucket_key, attempt_count, window_started_at)
  VALUES (p_bucket_key, 1, NOW())
  ON CONFLICT (bucket_key) DO UPDATE
  SET
    attempt_count = CASE
      WHEN public.rate_limit_buckets.window_started_at < NOW() - (p_window_seconds || ' seconds')::interval
        THEN 1
      ELSE public.rate_limit_buckets.attempt_count + 1
    END,
    window_started_at = CASE
      WHEN public.rate_limit_buckets.window_started_at < NOW() - (p_window_seconds || ' seconds')::interval
        THEN NOW()
      ELSE public.rate_limit_buckets.window_started_at
    END
  RETURNING * INTO bucket;

  RETURN bucket.attempt_count <= p_max_attempts;
END;
$$;
