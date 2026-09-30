-- =========================================================================
-- 005: "what are we watching tonight" polls with single-choice voting
-- =========================================================================

CREATE TABLE IF NOT EXISTS public.family_watch_polls (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  family_id uuid NOT NULL REFERENCES public.families(id) ON DELETE CASCADE,
  created_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  title varchar(255) NOT NULL DEFAULT 'Что смотрим сегодня?',
  is_open boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  closed_at timestamptz
);

CREATE TABLE IF NOT EXISTS public.family_watch_poll_options (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  poll_id uuid NOT NULL REFERENCES public.family_watch_polls(id) ON DELETE CASCADE,
  series_id uuid NOT NULL REFERENCES public.family_series(id) ON DELETE CASCADE,
  UNIQUE (poll_id, series_id)
);

CREATE TABLE IF NOT EXISTS public.family_watch_poll_votes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  poll_id uuid NOT NULL REFERENCES public.family_watch_polls(id) ON DELETE CASCADE,
  option_id uuid NOT NULL REFERENCES public.family_watch_poll_options(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  UNIQUE (poll_id, user_id)
);

CREATE INDEX IF NOT EXISTS family_watch_polls_family_id_index
  ON public.family_watch_polls (family_id);
CREATE INDEX IF NOT EXISTS family_watch_poll_options_poll_id_index
  ON public.family_watch_poll_options (poll_id);
CREATE INDEX IF NOT EXISTS family_watch_poll_votes_option_id_index
  ON public.family_watch_poll_votes (option_id);

ALTER TABLE public.family_watch_polls ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.family_watch_polls FORCE ROW LEVEL SECURITY;
ALTER TABLE public.family_watch_poll_options ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.family_watch_poll_options FORCE ROW LEVEL SECURITY;
ALTER TABLE public.family_watch_poll_votes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.family_watch_poll_votes FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS family_watch_polls_select_member ON public.family_watch_polls;
CREATE POLICY family_watch_polls_select_member
  ON public.family_watch_polls
  FOR SELECT
  USING (public.is_family_member(family_id));

DROP POLICY IF EXISTS family_watch_polls_insert_member ON public.family_watch_polls;
CREATE POLICY family_watch_polls_insert_member
  ON public.family_watch_polls
  FOR INSERT
  WITH CHECK (
    public.is_family_member(family_id)
    AND created_by = public.current_user_id()
  );

DROP POLICY IF EXISTS family_watch_polls_update_member ON public.family_watch_polls;
CREATE POLICY family_watch_polls_update_member
  ON public.family_watch_polls
  FOR UPDATE
  USING (public.is_family_member(family_id))
  WITH CHECK (public.is_family_member(family_id));

DROP POLICY IF EXISTS family_watch_polls_delete_creator_or_owner ON public.family_watch_polls;
CREATE POLICY family_watch_polls_delete_creator_or_owner
  ON public.family_watch_polls
  FOR DELETE
  USING (
    created_by = public.current_user_id()
    OR public.is_family_owner(family_id)
  );

DROP POLICY IF EXISTS family_watch_poll_options_select_member ON public.family_watch_poll_options;
CREATE POLICY family_watch_poll_options_select_member
  ON public.family_watch_poll_options
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.family_watch_polls poll
      WHERE poll.id = family_watch_poll_options.poll_id
        AND public.is_family_member(poll.family_id)
    )
  );

DROP POLICY IF EXISTS family_watch_poll_options_insert_member ON public.family_watch_poll_options;
CREATE POLICY family_watch_poll_options_insert_member
  ON public.family_watch_poll_options
  FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.family_watch_polls poll
      WHERE poll.id = family_watch_poll_options.poll_id
        AND public.is_family_member(poll.family_id)
    )
  );

DROP POLICY IF EXISTS family_watch_poll_options_delete_member ON public.family_watch_poll_options;
CREATE POLICY family_watch_poll_options_delete_member
  ON public.family_watch_poll_options
  FOR DELETE
  USING (
    EXISTS (
      SELECT 1 FROM public.family_watch_polls poll
      WHERE poll.id = family_watch_poll_options.poll_id
        AND public.is_family_member(poll.family_id)
    )
  );

DROP POLICY IF EXISTS family_watch_poll_votes_select_member ON public.family_watch_poll_votes;
CREATE POLICY family_watch_poll_votes_select_member
  ON public.family_watch_poll_votes
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.family_watch_polls poll
      WHERE poll.id = family_watch_poll_votes.poll_id
        AND public.is_family_member(poll.family_id)
    )
  );

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
  );

DROP POLICY IF EXISTS family_watch_poll_votes_update_own ON public.family_watch_poll_votes;
CREATE POLICY family_watch_poll_votes_update_own
  ON public.family_watch_poll_votes
  FOR UPDATE
  USING (user_id = public.current_user_id())
  WITH CHECK (user_id = public.current_user_id());

DROP POLICY IF EXISTS family_watch_poll_votes_delete_own ON public.family_watch_poll_votes;
CREATE POLICY family_watch_poll_votes_delete_own
  ON public.family_watch_poll_votes
  FOR DELETE
  USING (user_id = public.current_user_id());
