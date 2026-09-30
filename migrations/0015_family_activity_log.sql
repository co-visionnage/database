-- =========================================================================
-- 014: family activity log
--
-- A lightweight audit trail so an owner can see who added/removed a
-- series or changed a member's role. actor_user_id cascades to NULL
-- (rather than deleting the row) so the log survives self-service
-- account deletion; actor_label/target_label are captured at write time
-- so the log stays readable even after that.
-- =========================================================================

CREATE TABLE IF NOT EXISTS public.family_activity_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  family_id uuid NOT NULL REFERENCES public.families(id) ON DELETE CASCADE,
  actor_user_id uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  actor_label text NOT NULL,
  action varchar(50) NOT NULL,
  target_label text,
  detail text,
  created_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS family_activity_log_family_id_index
  ON public.family_activity_log (family_id, created_at DESC);

ALTER TABLE public.family_activity_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.family_activity_log FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS family_activity_log_select_member ON public.family_activity_log;
CREATE POLICY family_activity_log_select_member
  ON public.family_activity_log
  FOR SELECT
  USING (public.is_family_member(family_id));

DROP POLICY IF EXISTS family_activity_log_insert_member ON public.family_activity_log;
CREATE POLICY family_activity_log_insert_member
  ON public.family_activity_log
  FOR INSERT
  WITH CHECK (
    public.is_family_member(family_id)
    AND (actor_user_id IS NULL OR actor_user_id = public.current_user_id())
  );
