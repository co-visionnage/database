-- =========================================================================
-- 024: closed polls could still be voted on, and any member could close one
--
-- 1. family_watch_poll_votes_upsert_own/_update_own never checked
--    family_watch_polls.is_open -- voteWatchPollAction is reachable at any
--    time by any family member, and its ON CONFLICT DO UPDATE path let a
--    member silently rewrite their vote (or cast a first one) after the
--    poll's creator had already called closeWatchPollAction and the app
--    started treating the result as final. is_open is only enforced in the
--    UI, not the database.
--
-- 2. family_watch_polls_update_member allowed ANY family member to run the
--    poll's only UPDATE statement (closeWatchPollAction), unlike DELETE
--    which is already creator-or-owner-only. Any member could close --or,
--    since the same broad policy also covers title edits generally-- rename
--    a poll they didn't create.
-- =========================================================================

DROP POLICY IF EXISTS family_watch_poll_votes_upsert_own ON public.family_watch_poll_votes;
CREATE POLICY family_watch_poll_votes_upsert_own
  ON public.family_watch_poll_votes
  FOR INSERT
  WITH CHECK (
    user_id = public.current_user_id()
    AND EXISTS (
      SELECT 1 FROM public.family_watch_polls poll
      WHERE poll.id = family_watch_poll_votes.poll_id
        AND public.is_family_member(poll.family_id)
        AND poll.is_open
    )
    AND EXISTS (
      SELECT 1 FROM public.family_watch_poll_options option
      WHERE option.id = family_watch_poll_votes.option_id
        AND option.poll_id = family_watch_poll_votes.poll_id
    )
  );

DROP POLICY IF EXISTS family_watch_poll_votes_update_own ON public.family_watch_poll_votes;
CREATE POLICY family_watch_poll_votes_update_own
  ON public.family_watch_poll_votes
  FOR UPDATE
  USING (user_id = public.current_user_id())
  WITH CHECK (
    user_id = public.current_user_id()
    AND EXISTS (
      SELECT 1 FROM public.family_watch_polls poll
      WHERE poll.id = family_watch_poll_votes.poll_id
        AND poll.is_open
    )
    AND EXISTS (
      SELECT 1 FROM public.family_watch_poll_options option
      WHERE option.id = family_watch_poll_votes.option_id
        AND option.poll_id = family_watch_poll_votes.poll_id
    )
  );

DROP POLICY IF EXISTS family_watch_polls_update_member ON public.family_watch_polls;
CREATE POLICY family_watch_polls_update_creator_or_owner
  ON public.family_watch_polls
  FOR UPDATE
  USING (
    created_by = public.current_user_id()
    OR public.is_family_owner(family_id)
  )
  WITH CHECK (
    created_by = public.current_user_id()
    OR public.is_family_owner(family_id)
  );
