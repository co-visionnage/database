-- =========================================================================
-- 013: TOTP-based two-factor authentication
--
-- get_profile_auth_by_email now also returns totp_enabled so login can
-- decide whether to finish immediately or ask for a code first (its
-- RETURNS TABLE column list changed, hence the DROP FUNCTION below —
-- CREATE OR REPLACE alone can't do that). get_totp_secret_for_login is the
-- pre-session counterpart used once a password has already checked out but
-- before a session exists, so it deliberately isn't scoped to
-- current_user_id().
-- =========================================================================

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS totp_secret text,
  ADD COLUMN IF NOT EXISTS totp_enabled boolean NOT NULL DEFAULT false;

-- Postgres won't let CREATE OR REPLACE change a RETURNS TABLE column list
-- (even by only appending), so the old 4-column signature has to go first.
DROP FUNCTION IF EXISTS public.get_profile_auth_by_email(text);

CREATE OR REPLACE FUNCTION public.get_profile_auth_by_email(p_email text)
RETURNS TABLE (
  user_id uuid,
  email text,
  display_name varchar(50),
  password_hash text,
  totp_enabled boolean
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    profile.id AS user_id,
    profile.email AS email,
    profile.display_name AS display_name,
    profile.password_hash AS password_hash,
    profile.totp_enabled AS totp_enabled
  FROM public.profiles AS profile
  WHERE profile.email = LOWER(TRIM(p_email))
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.get_totp_secret_for_login(p_user_id uuid)
RETURNS text
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT totp_secret
  FROM public.profiles
  WHERE id = p_user_id
    AND totp_enabled = true;
$$;
