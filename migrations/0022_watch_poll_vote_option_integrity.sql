-- =========================================================================
-- 022: a poll vote's option must actually belong to that poll
--
-- family_watch_poll_votes_upsert_own only checked that poll_id belongs to a
-- family the voter is a member of -- it never checked that option_id is one
-- of THAT poll's options. Since option_id only has to exist somewhere (the
-- FK doesn't care which poll it's under), a member of family A could insert
-- a vote with poll_id = one of family A's own polls (satisfying the RLS
-- check) but option_id = an option belonging to family B's poll. The tally
-- in getFamilyWatchPolls joins votes to options by option_id alone, so that
-- vote silently counts toward family B's poll -- a family A member
-- injecting votes into a poll they have no access to. The same gap existed
-- on the UPDATE policy, reachable via the ON CONFLICT DO UPDATE path in
-- voteWatchPollAction.
--
-- NOTE ON MIGRATION NUMBERING: this was written as 0022 against origin/main
-- at a point where another not-yet-merged branch also adds a migration
-- numbered 0021 (two_factor_challenges). Whichever of these two PRs merges
-- second will need its migration renumbered to avoid a filename collision
-- -- there is no ordering dependency between the two, so either number
-- assignment is fine as long as they don't collide.
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
      SELECT 1 FROM public.family_watch_poll_options option
      WHERE option.id = family_watch_poll_votes.option_id
        AND option.poll_id = family_watch_poll_votes.poll_id
    )
  );
