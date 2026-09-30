-- =========================================================================
-- 021: bind the 2FA verification step to a prior successful password check
--
-- Previously, loginUserSession returned the bare userId once the password
-- checked out, and /api/auth/verify-2fa accepted {userId, code} straight
-- from the client with nothing tying the request back to that password
-- check -- userId isn't secret (it's returned by /api/family/members), so
-- 2FA alone was the entire login for any account with it enabled.
--
-- Password verification now issues a short-lived, single-use, opaque
-- challenge token (same hashed-random-token shape as app_sessions) that
-- the client must present alongside the TOTP code. Only its holder -- i.e.
-- whoever just supplied the correct password -- can attempt the code.
-- =========================================================================

CREATE TABLE IF NOT EXISTS public.two_factor_challenges (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  token_hash text UNIQUE NOT NULL,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE OR REPLACE FUNCTION public.create_two_factor_challenge(
  p_user_id uuid,
  p_token_hash text,
  p_expires_at timestamptz
)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  DELETE FROM public.two_factor_challenges WHERE user_id = p_user_id;
  INSERT INTO public.two_factor_challenges (token_hash, user_id, expires_at)
  VALUES (p_token_hash, p_user_id, p_expires_at);
$$;

-- Deliberately read-only (doesn't consume the challenge): a wrong TOTP
-- guess shouldn't force the user back to the password step, so the
-- challenge stays valid for retries until it expires or a correct code
-- consumes it via delete_two_factor_challenge below. Brute-forcing the code
-- within that window is bounded by rate limiting in the route handler.
CREATE OR REPLACE FUNCTION public.get_two_factor_challenge(p_token_hash text)
RETURNS uuid
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT user_id
  FROM public.two_factor_challenges
  WHERE token_hash = p_token_hash
    AND expires_at > NOW();
$$;

CREATE OR REPLACE FUNCTION public.delete_two_factor_challenge(p_token_hash text)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  DELETE FROM public.two_factor_challenges WHERE token_hash = p_token_hash;
$$;

ALTER TABLE public.two_factor_challenges ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.two_factor_challenges FORCE ROW LEVEL SECURITY;

-- No direct table access from the app role at all -- every operation goes
-- through the SECURITY DEFINER functions above, which is what makes it
-- safe for this table to be reachable pre-session (no app.current_user_id
-- exists yet at this point in the login flow).
DROP POLICY IF EXISTS two_factor_challenges_no_access ON public.two_factor_challenges;
CREATE POLICY two_factor_challenges_no_access
  ON public.two_factor_challenges
  USING (false);
