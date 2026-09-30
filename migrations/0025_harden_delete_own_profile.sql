-- =========================================================================
-- 025: delete_own_profile should not trust its p_user_id argument alone
--
-- delete_own_profile is SECURITY DEFINER, so it bypasses RLS by design --
-- it has to, since ON DELETE CASCADE from profiles is how account deletion
-- reaches every table the deleted user owns. The only caller today
-- (deleteAccountAction) always passes the caller's own user.id, so this is
-- not exploitable right now, but the function itself had no assertion that
-- p_user_id actually matched the calling session -- any future call site
-- that forwarded a client-supplied id would turn this into an unrestricted
-- delete-any-account primitive that RLS cannot catch, since the function
-- bypasses it entirely.
--
-- Scoping the DELETE to `AND id = public.current_user_id()` costs nothing
-- for the legitimate case and makes the function safe by construction
-- regardless of what argument a future caller passes.
-- =========================================================================

CREATE OR REPLACE FUNCTION public.delete_own_profile(p_user_id uuid)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
AS $$
  DELETE FROM public.profiles
  WHERE id = p_user_id
    AND id = public.current_user_id();
$$;
