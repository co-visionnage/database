CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE OR REPLACE FUNCTION public.current_user_id()
RETURNS uuid
LANGUAGE sql
STABLE
AS $$
  SELECT NULLIF(current_setting('app.current_user_id', true), '')::uuid;
$$;

CREATE OR REPLACE FUNCTION public.touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

CREATE TABLE IF NOT EXISTS public.profiles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email text UNIQUE NOT NULL,
  display_name varchar(50),
  password_hash text,
  avatar_url text,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.app_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  token_hash text UNIQUE NOT NULL,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.families (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name varchar(255) NOT NULL,
  owner_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  invite_code varchar(50) UNIQUE NOT NULL,
  created_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.family_members (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  family_id uuid NOT NULL REFERENCES public.families(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  role varchar(20) NOT NULL DEFAULT 'member' CHECK (role IN ('owner', 'member')),
  joined_at timestamptz NOT NULL DEFAULT NOW(),
  UNIQUE (family_id, user_id)
);

CREATE TABLE IF NOT EXISTS public.family_series (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  family_id uuid NOT NULL REFERENCES public.families(id) ON DELETE CASCADE,
  title varchar(255) NOT NULL,
  genres varchar(50)[] NOT NULL DEFAULT '{}'::varchar(50)[],
  year integer,
  image_url text,
  created_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.family_series_status (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  series_id uuid NOT NULL REFERENCES public.family_series(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  status varchar(20) NOT NULL CHECK (status IN ('watched', 'to-watch')),
  rating integer CHECK (rating IS NULL OR rating BETWEEN 1 AND 5),
  comment text,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW(),
  UNIQUE (series_id, user_id)
);

CREATE INDEX IF NOT EXISTS families_owner_id_index ON public.families (owner_id);
CREATE INDEX IF NOT EXISTS families_invite_code_index ON public.families (invite_code);
CREATE INDEX IF NOT EXISTS family_members_user_id_index ON public.family_members (user_id);
CREATE INDEX IF NOT EXISTS family_members_family_id_index ON public.family_members (family_id);
CREATE INDEX IF NOT EXISTS family_series_family_id_index ON public.family_series (family_id);
CREATE INDEX IF NOT EXISTS family_series_status_user_id_index ON public.family_series_status (user_id);
CREATE INDEX IF NOT EXISTS family_series_status_series_id_index ON public.family_series_status (series_id);

DROP TRIGGER IF EXISTS profiles_touch_updated_at ON public.profiles;
CREATE TRIGGER profiles_touch_updated_at
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.touch_updated_at();

DROP TRIGGER IF EXISTS family_series_touch_updated_at ON public.family_series;
CREATE TRIGGER family_series_touch_updated_at
  BEFORE UPDATE ON public.family_series
  FOR EACH ROW
  EXECUTE FUNCTION public.touch_updated_at();

DROP TRIGGER IF EXISTS family_series_status_touch_updated_at ON public.family_series_status;
CREATE TRIGGER family_series_status_touch_updated_at
  BEFORE UPDATE ON public.family_series_status
  FOR EACH ROW
  EXECUTE FUNCTION public.touch_updated_at();

CREATE OR REPLACE FUNCTION public.is_family_member(target_family_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.family_members member
    WHERE member.family_id = target_family_id
      AND member.user_id = public.current_user_id()
  );
$$;

CREATE OR REPLACE FUNCTION public.is_family_owner(target_family_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.families family
    WHERE family.id = target_family_id
      AND family.owner_id = public.current_user_id()
  );
$$;

CREATE OR REPLACE FUNCTION public.create_profile_session(
  p_email text,
  p_display_name text,
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
BEGIN
  INSERT INTO public.profiles (email, display_name)
  VALUES (LOWER(TRIM(p_email)), NULLIF(TRIM(p_display_name), ''))
  ON CONFLICT ON CONSTRAINT profiles_email_key DO UPDATE
  SET display_name = COALESCE(EXCLUDED.display_name, public.profiles.display_name),
      updated_at = NOW()
  RETURNING * INTO created_profile;

  DELETE FROM public.app_sessions AS session
  WHERE session.user_id = created_profile.id;

  INSERT INTO public.app_sessions (token_hash, user_id, expires_at)
  VALUES (p_token_hash, created_profile.id, p_expires_at);

  RETURN QUERY
  SELECT
    created_profile.id AS user_id,
    created_profile.email AS email,
    created_profile.display_name AS display_name;
END;
$$;

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
BEGIN
  INSERT INTO public.profiles (email, display_name, password_hash)
  VALUES (
    LOWER(TRIM(p_email)),
    NULLIF(TRIM(p_display_name), ''),
    p_password_hash
  )
  ON CONFLICT ON CONSTRAINT profiles_email_key DO UPDATE
  SET
    display_name = COALESCE(EXCLUDED.display_name, public.profiles.display_name),
    password_hash = CASE
      WHEN public.profiles.password_hash IS NULL THEN EXCLUDED.password_hash
      ELSE public.profiles.password_hash
    END,
    updated_at = NOW()
  RETURNING * INTO created_profile;

  IF created_profile.password_hash IS DISTINCT FROM p_password_hash
     AND created_profile.password_hash IS NOT NULL THEN
    RAISE EXCEPTION 'ACCOUNT_ALREADY_EXISTS';
  END IF;

  INSERT INTO public.app_sessions (token_hash, user_id, expires_at)
  VALUES (p_token_hash, created_profile.id, p_expires_at);

  RETURN QUERY
  SELECT
    created_profile.id AS user_id,
    created_profile.email AS email,
    created_profile.display_name AS display_name;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_profile_auth_by_email(p_email text)
RETURNS TABLE (
  user_id uuid,
  email text,
  display_name varchar(50),
  password_hash text
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    profile.id AS user_id,
    profile.email AS email,
    profile.display_name AS display_name,
    profile.password_hash AS password_hash
  FROM public.profiles AS profile
  WHERE profile.email = LOWER(TRIM(p_email))
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.create_session_for_profile(
  p_user_id uuid,
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
  target_profile public.profiles;
BEGIN
  SELECT *
  INTO target_profile
  FROM public.profiles AS profile
  WHERE profile.id = p_user_id
  LIMIT 1;

  DELETE FROM public.app_sessions AS session
  WHERE session.user_id = p_user_id;

  INSERT INTO public.app_sessions (token_hash, user_id, expires_at)
  VALUES (p_token_hash, p_user_id, p_expires_at);

  RETURN QUERY
  SELECT
    target_profile.id AS user_id,
    target_profile.email AS email,
    target_profile.display_name AS display_name;
END;
$$;

CREATE OR REPLACE FUNCTION public.find_family_by_invite_code(p_invite_code text)
RETURNS TABLE (
  family_id uuid,
  name varchar(255),
  invite_code varchar(50)
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    family.id AS family_id,
    family.name AS name,
    family.invite_code AS invite_code
  FROM public.families AS family
  WHERE family.invite_code = UPPER(TRIM(p_invite_code))
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.get_session_user(p_token_hash text)
RETURNS TABLE (
  session_id uuid,
  user_id uuid,
  email text,
  display_name varchar(50),
  expires_at timestamptz
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    session.id AS session_id,
    profile.id AS user_id,
    profile.email AS email,
    profile.display_name AS display_name,
    session.expires_at AS expires_at
  FROM public.app_sessions session
  JOIN public.profiles profile ON profile.id = session.user_id
  WHERE session.token_hash = p_token_hash
    AND session.expires_at > NOW()
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.delete_session_by_token(p_token_hash text)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  DELETE FROM public.app_sessions WHERE token_hash = p_token_hash;
$$;

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.profiles FORCE ROW LEVEL SECURITY;
ALTER TABLE public.app_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.app_sessions FORCE ROW LEVEL SECURITY;
ALTER TABLE public.families ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.families FORCE ROW LEVEL SECURITY;
ALTER TABLE public.family_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.family_members FORCE ROW LEVEL SECURITY;
ALTER TABLE public.family_series ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.family_series FORCE ROW LEVEL SECURITY;
ALTER TABLE public.family_series_status ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.family_series_status FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS profiles_select_self ON public.profiles;
CREATE POLICY profiles_select_self
  ON public.profiles
  FOR SELECT
  USING (id = public.current_user_id());

DROP POLICY IF EXISTS profiles_update_self ON public.profiles;
CREATE POLICY profiles_update_self
  ON public.profiles
  FOR UPDATE
  USING (id = public.current_user_id())
  WITH CHECK (id = public.current_user_id());

DROP POLICY IF EXISTS app_sessions_owner_only ON public.app_sessions;
CREATE POLICY app_sessions_owner_only
  ON public.app_sessions
  FOR ALL
  USING (user_id = public.current_user_id())
  WITH CHECK (user_id = public.current_user_id());

DROP POLICY IF EXISTS families_select_member ON public.families;
CREATE POLICY families_select_member
  ON public.families
  FOR SELECT
  USING (owner_id = public.current_user_id() OR public.is_family_member(id));

DROP POLICY IF EXISTS families_insert_owner ON public.families;
CREATE POLICY families_insert_owner
  ON public.families
  FOR INSERT
  WITH CHECK (owner_id = public.current_user_id());

DROP POLICY IF EXISTS families_update_owner ON public.families;
CREATE POLICY families_update_owner
  ON public.families
  FOR UPDATE
  USING (owner_id = public.current_user_id())
  WITH CHECK (owner_id = public.current_user_id());

DROP POLICY IF EXISTS families_delete_owner ON public.families;
CREATE POLICY families_delete_owner
  ON public.families
  FOR DELETE
  USING (owner_id = public.current_user_id());

DROP POLICY IF EXISTS family_members_select_related ON public.family_members;
CREATE POLICY family_members_select_related
  ON public.family_members
  FOR SELECT
  USING (
    user_id = public.current_user_id()
    OR public.is_family_owner(family_id)
    OR public.is_family_member(family_id)
  );

DROP POLICY IF EXISTS family_members_insert_self ON public.family_members;
CREATE POLICY family_members_insert_self
  ON public.family_members
  FOR INSERT
  WITH CHECK (
    user_id = public.current_user_id()
    AND (
      role = 'member'
      OR (
        role = 'owner'
        AND EXISTS (
          SELECT 1
          FROM public.families family
          WHERE family.id = family_members.family_id
          AND family.owner_id = public.current_user_id()
        )
      )
    )
  );

DROP POLICY IF EXISTS family_members_delete_self_or_owner ON public.family_members;
CREATE POLICY family_members_delete_self_or_owner
  ON public.family_members
  FOR DELETE
  USING (user_id = public.current_user_id() OR public.is_family_owner(family_id));

DROP POLICY IF EXISTS family_series_select_member ON public.family_series;
CREATE POLICY family_series_select_member
  ON public.family_series
  FOR SELECT
  USING (public.is_family_member(family_id));

DROP POLICY IF EXISTS family_series_insert_member ON public.family_series;
CREATE POLICY family_series_insert_member
  ON public.family_series
  FOR INSERT
  WITH CHECK (
    public.is_family_member(family_id)
    AND created_by = public.current_user_id()
  );

DROP POLICY IF EXISTS family_series_update_member ON public.family_series;
CREATE POLICY family_series_update_member
  ON public.family_series
  FOR UPDATE
  USING (public.is_family_member(family_id))
  WITH CHECK (public.is_family_member(family_id));

DROP POLICY IF EXISTS family_series_delete_member ON public.family_series;
CREATE POLICY family_series_delete_member
  ON public.family_series
  FOR DELETE
  USING (public.is_family_member(family_id));

DROP POLICY IF EXISTS family_series_status_select_owner ON public.family_series_status;
CREATE POLICY family_series_status_select_owner
  ON public.family_series_status
  FOR SELECT
  USING (
    user_id = public.current_user_id()
    AND EXISTS (
      SELECT 1
      FROM public.family_series series
      WHERE series.id = family_series_status.series_id
        AND public.is_family_member(series.family_id)
    )
  );

DROP POLICY IF EXISTS family_series_status_insert_owner ON public.family_series_status;
CREATE POLICY family_series_status_insert_owner
  ON public.family_series_status
  FOR INSERT
  WITH CHECK (
    user_id = public.current_user_id()
    AND EXISTS (
      SELECT 1
      FROM public.family_series series
      WHERE series.id = family_series_status.series_id
        AND public.is_family_member(series.family_id)
    )
  );

DROP POLICY IF EXISTS family_series_status_update_owner ON public.family_series_status;
CREATE POLICY family_series_status_update_owner
  ON public.family_series_status
  FOR UPDATE
  USING (
    user_id = public.current_user_id()
    AND EXISTS (
      SELECT 1
      FROM public.family_series series
      WHERE series.id = family_series_status.series_id
        AND public.is_family_member(series.family_id)
    )
  )
  WITH CHECK (
    user_id = public.current_user_id()
    AND EXISTS (
      SELECT 1
      FROM public.family_series series
      WHERE series.id = family_series_status.series_id
        AND public.is_family_member(series.family_id)
    )
  );

DROP POLICY IF EXISTS family_series_status_delete_owner ON public.family_series_status;
CREATE POLICY family_series_status_delete_owner
  ON public.family_series_status
  FOR DELETE
  USING (user_id = public.current_user_id());
