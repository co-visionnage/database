-- =========================================================================
-- 020: make mark_progress_reminded an atomic claim
--
-- The inactivity-nudge cron (check-inactive) reads stale rows with
-- get_stale_progress, sends a notification, then calls
-- mark_progress_reminded last. Two overlapping/retried invocations can
-- both read the same stale row before either marks it reminded, sending
-- duplicate nudges. Redefining the WHERE clause to re-check the same
-- staleness condition and returning whether a row was actually updated
-- lets the caller claim the row first (single atomic UPDATE) and only
-- send the notification if the claim succeeded.
-- =========================================================================

DROP FUNCTION IF EXISTS public.mark_progress_reminded(uuid, uuid);

CREATE FUNCTION public.mark_progress_reminded(
  target_series_id uuid,
  target_user_id uuid
)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
AS $$
  UPDATE public.family_series_progress
  SET last_reminded_at = NOW()
  WHERE series_id = target_series_id
    AND user_id = target_user_id
    AND (
      last_reminded_at IS NULL
      OR last_reminded_at < NOW() - INTERVAL '7 days'
    )
  RETURNING true;
$$;
