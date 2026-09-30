-- =========================================================================
-- 016: scheduled watch-together events with RSVP
--
-- Distinct from family_watch_polls (which picks WHAT to watch): this is
-- WHEN, with a lightweight going/maybe/no RSVP per member. series_id is
-- optional and set NULL on delete rather than cascading — losing the
-- linked series shouldn't wipe out the (already-scheduled) event.
-- =========================================================================

CREATE TABLE IF NOT EXISTS public.family_watch_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  family_id uuid NOT NULL REFERENCES public.families(id) ON DELETE CASCADE,
  series_id uuid REFERENCES public.family_series(id) ON DELETE SET NULL,
  created_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  title varchar(255) NOT NULL,
  scheduled_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.family_watch_event_rsvps (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id uuid NOT NULL REFERENCES public.family_watch_events(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  status varchar(10) NOT NULL CHECK (status IN ('going', 'maybe', 'no')),
  updated_at timestamptz NOT NULL DEFAULT NOW(),
  UNIQUE (event_id, user_id)
);

CREATE INDEX IF NOT EXISTS family_watch_events_family_id_index
  ON public.family_watch_events (family_id, scheduled_at);
CREATE INDEX IF NOT EXISTS family_watch_event_rsvps_event_id_index
  ON public.family_watch_event_rsvps (event_id);

DROP TRIGGER IF EXISTS family_watch_event_rsvps_touch_updated_at ON public.family_watch_event_rsvps;
CREATE TRIGGER family_watch_event_rsvps_touch_updated_at
  BEFORE UPDATE ON public.family_watch_event_rsvps
  FOR EACH ROW
  EXECUTE FUNCTION public.touch_updated_at();

ALTER TABLE public.family_watch_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.family_watch_events FORCE ROW LEVEL SECURITY;
ALTER TABLE public.family_watch_event_rsvps ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.family_watch_event_rsvps FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS family_watch_events_select_member ON public.family_watch_events;
CREATE POLICY family_watch_events_select_member
  ON public.family_watch_events
  FOR SELECT
  USING (public.is_family_member(family_id));

DROP POLICY IF EXISTS family_watch_events_insert_member ON public.family_watch_events;
CREATE POLICY family_watch_events_insert_member
  ON public.family_watch_events
  FOR INSERT
  WITH CHECK (
    public.is_family_member(family_id)
    AND created_by = public.current_user_id()
  );

DROP POLICY IF EXISTS family_watch_events_delete_creator_or_owner ON public.family_watch_events;
CREATE POLICY family_watch_events_delete_creator_or_owner
  ON public.family_watch_events
  FOR DELETE
  USING (
    created_by = public.current_user_id()
    OR public.is_family_owner(family_id)
  );

DROP POLICY IF EXISTS family_watch_event_rsvps_select_member ON public.family_watch_event_rsvps;
CREATE POLICY family_watch_event_rsvps_select_member
  ON public.family_watch_event_rsvps
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.family_watch_events event
      WHERE event.id = family_watch_event_rsvps.event_id
        AND public.is_family_member(event.family_id)
    )
  );

DROP POLICY IF EXISTS family_watch_event_rsvps_upsert_own ON public.family_watch_event_rsvps;
CREATE POLICY family_watch_event_rsvps_upsert_own
  ON public.family_watch_event_rsvps
  FOR INSERT
  WITH CHECK (
    user_id = public.current_user_id()
    AND EXISTS (
      SELECT 1 FROM public.family_watch_events event
      WHERE event.id = family_watch_event_rsvps.event_id
        AND public.is_family_member(event.family_id)
    )
  );

DROP POLICY IF EXISTS family_watch_event_rsvps_update_own ON public.family_watch_event_rsvps;
CREATE POLICY family_watch_event_rsvps_update_own
  ON public.family_watch_event_rsvps
  FOR UPDATE
  USING (user_id = public.current_user_id())
  WITH CHECK (user_id = public.current_user_id());

DROP POLICY IF EXISTS family_watch_event_rsvps_delete_own ON public.family_watch_event_rsvps;
CREATE POLICY family_watch_event_rsvps_delete_own
  ON public.family_watch_event_rsvps
  FOR DELETE
  USING (user_id = public.current_user_id());
