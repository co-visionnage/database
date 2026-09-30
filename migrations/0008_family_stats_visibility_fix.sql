-- =========================================================================
-- 008: fix family stats / recommendations / history only ever seeing your
-- own watched rows.
--
-- family_series_status_select_owner restricts SELECT to `user_id =
-- current_user_id()`, which was correct for the original 1:1 "your status
-- on a shared series" use case, but it silently made getFamilyStats(),
-- getRecommendations() and the new watch-history query aggregate only the
-- CALLING user's own rows and label the result "family" stats. This adds a
-- second permissive SELECT policy (combined with OR, same pattern as the
-- profiles fix above) so any family member can read the whole family's
-- watch status/rating/comment/watched_at for aggregate features.
-- =========================================================================

DROP POLICY IF EXISTS family_series_status_select_family ON public.family_series_status;
CREATE POLICY family_series_status_select_family
  ON public.family_series_status
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.family_series series
      WHERE series.id = family_series_status.series_id
        AND public.is_family_member(series.family_id)
    )
  );
