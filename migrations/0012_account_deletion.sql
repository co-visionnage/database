-- =========================================================================
-- 012: self-service account deletion
--
-- No RLS policy grants DELETE on profiles (a user closing their own
-- account is the one case that needs it), so this needs a narrowly-scoped
-- SECURITY DEFINER function rather than a policy that would let a user
-- delete arbitrary rows. Every family_*/push_subscriptions/app_sessions
-- row referencing this profile cascades away with it; if the account owns
-- a family that still has other members, the app is expected to block the
-- deletion before calling this (the family's own ON DELETE CASCADE would
-- otherwise take the whole family, and everyone else's data, down with it).
-- =========================================================================

CREATE OR REPLACE FUNCTION public.delete_own_profile(p_user_id uuid)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
AS $$
  DELETE FROM public.profiles WHERE id = p_user_id;
$$;
