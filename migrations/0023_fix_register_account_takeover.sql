-- =========================================================================
-- 023: password registration could take over an existing OAuth account
--
-- register_profile_account used INSERT ... ON CONFLICT DO UPDATE, and its
-- password_hash branch only overwrote NULL (i.e. OAuth-only) hashes:
--
--   password_hash = CASE
--     WHEN public.profiles.password_hash IS NULL THEN EXCLUDED.password_hash
--     ELSE public.profiles.password_hash
--   END
--
-- Since a GitHub-OAuth profile always has password_hash = NULL, registering
-- with an OAuth user's email silently attached the attacker's password to
-- that victim's existing row and logged the attacker into the victim's
-- session -- no email verification exists anywhere in this app to have
-- caught it, and it also skipped the victim's TOTP check entirely (that
-- only runs on the login path). The ACCOUNT_ALREADY_EXISTS guard only fired
-- when the existing hash was non-NULL *and* differed from the submitted
-- one, which is never true right after the UPDATE just set them equal.
--
-- Fixed by never touching an existing row: registration now always fails
-- with ACCOUNT_ALREADY_EXISTS if a profile with that email exists already,
-- password_hash NULL or not. Claiming a password login for an OAuth-created
-- account is a legitimate feature, but it needs actual proof of email
-- ownership (a verification link) to be safe -- not implemented here.
-- =========================================================================

CREATE OR REPLACE FUNCTION public.register_profile_account(
  p_email text,
  p_display_name text,
  p_password_hash text,
  p_token_hash text,
  p_expires_at timestamptz
)
RETURNS TABLE (
  user_id uuid,
  email text,
  display_name varchar(50)
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  created_profile public.profiles;
  normalized_email text := LOWER(TRIM(p_email));
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.profiles WHERE profiles.email = normalized_email
  ) THEN
    RAISE EXCEPTION 'ACCOUNT_ALREADY_EXISTS';
  END IF;

  INSERT INTO public.profiles (email, display_name, password_hash)
  VALUES (
    normalized_email,
    NULLIF(TRIM(p_display_name), ''),
    p_password_hash
  )
  RETURNING * INTO created_profile;

  INSERT INTO public.app_sessions (token_hash, user_id, expires_at)
  VALUES (p_token_hash, created_profile.id, p_expires_at);

  RETURN QUERY
  SELECT
    created_profile.id AS user_id,
    created_profile.email AS email,
    created_profile.display_name AS display_name;
END;
$$;
