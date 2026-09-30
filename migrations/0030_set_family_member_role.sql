-- =========================================================================
-- 030: real SQL function for changing a family member's role
--
-- family_members has no UPDATE policy at all (see 0001_initial_schema.sql:
-- only SELECT/INSERT/DELETE are covered) -- a plain `UPDATE family_members
-- SET role = ... WHERE ...` run as app_user under RLS silently affects 0
-- rows regardless of who the caller is, since RLS default-denies with no
-- matching policy. This makes role changes a SECURITY DEFINER function
-- (same shape as transfer_family_ownership from 0006) instead of relying on
-- a raw UPDATE that can never actually succeed under RLS.
-- =========================================================================

CREATE OR REPLACE FUNCTION public.set_family_member_role(
  target_family_id uuid,
  target_user_id uuid,
  new_role text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  caller uuid := public.current_user_id();
  affected_rows integer;
BEGIN
  IF new_role NOT IN ('admin', 'member') THEN
    RAISE EXCEPTION 'Недопустимая роль';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.family_members
    WHERE family_id = target_family_id
      AND user_id = caller
      AND role = 'owner'
  ) THEN
    RAISE EXCEPTION 'Только владелец семьи может менять роли участников';
  END IF;

  UPDATE public.family_members
  SET role = new_role
  WHERE family_id = target_family_id
    AND user_id = target_user_id
    AND role != 'owner';

  GET DIAGNOSTICS affected_rows = ROW_COUNT;
  RETURN affected_rows > 0;
END;
$$;
