-- =========================================================================
-- 006: admin role + ownership transfer
-- =========================================================================

ALTER TABLE public.family_members DROP CONSTRAINT IF EXISTS family_members_role_check;
ALTER TABLE public.family_members
  ADD CONSTRAINT family_members_role_check CHECK (role IN ('owner', 'admin', 'member'));

CREATE OR REPLACE FUNCTION public.transfer_family_ownership(
  target_family_id uuid,
  new_owner_user_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  caller uuid := public.current_user_id();
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.families family
    WHERE family.id = target_family_id
      AND family.owner_id = caller
  ) THEN
    RAISE EXCEPTION 'Только текущий владелец может передать семью';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.family_members member
    WHERE member.family_id = target_family_id
      AND member.user_id = new_owner_user_id
  ) THEN
    RAISE EXCEPTION 'Новый владелец должен быть участником семьи';
  END IF;

  UPDATE public.families
  SET owner_id = new_owner_user_id
  WHERE id = target_family_id;

  UPDATE public.family_members
  SET role = 'member'
  WHERE family_id = target_family_id
    AND user_id = caller;

  UPDATE public.family_members
  SET role = 'owner'
  WHERE family_id = target_family_id
    AND user_id = new_owner_user_id;
END;
$$;
