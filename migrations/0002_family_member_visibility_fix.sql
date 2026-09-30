-- =========================================================================
-- 002: fix family member list only ever showing the current user
--
-- getFamilyMembers() joins family_members to profiles to display email /
-- display_name for every member. profiles_select_self only allowed a user
-- to read their own profile row, so the join silently dropped every other
-- family member. This adds a second permissive SELECT policy (Postgres
-- combines multiple permissive policies with OR) that also allows reading
-- the profile of anyone who shares a family with the caller.
-- =========================================================================

DROP POLICY IF EXISTS profiles_select_family_members ON public.profiles;
CREATE POLICY profiles_select_family_members
  ON public.profiles
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1
      FROM public.family_members mine
      JOIN public.family_members theirs
        ON theirs.family_id = mine.family_id
      WHERE mine.user_id = public.current_user_id()
        AND theirs.user_id = profiles.id
    )
  );
