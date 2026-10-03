-- =========================================================================
-- 038: приглашение в семью по email и welcome-письмо
--
-- Раньше вступить в семью можно было только по коду, который владелец
-- передавал сам. Теперь владелец или админ вводит email, и человеку уходит
-- письмо со ссылкой-приглашением.
--
-- Как и подтверждение email, токен приглашения создаёт воркер в момент
-- отправки письма: в outbox и NATS лежит только id приглашения. Токен
-- одноразовый, действует 7 дней, в БД хранится только его SHA-256. Приём
-- приглашения не требует совпадения email: токен -- это и есть доказательство
-- того, что письмо получено; человек может войти под другим адресом.
--
-- Welcome-письмо уходит один раз -- когда адрес подтверждён (по ссылке из
-- письма) либо когда аккаунт впервые создан через GitHub (адрес там уже
-- подтверждён самим GitHub).
-- =========================================================================

CREATE TABLE IF NOT EXISTS public.family_invitations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  family_id uuid NOT NULL REFERENCES public.families(id) ON DELETE CASCADE,
  email text NOT NULL,
  invited_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  token_hash text UNIQUE,
  expires_at timestamptz,
  accepted_at timestamptz,
  accepted_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT NOW()
);

-- Одно активное приглашение на пару «семья - адрес»: повторное
-- приглашение того же человека обновляет существующее, а не плодит строки.
CREATE UNIQUE INDEX IF NOT EXISTS family_invitations_pending_unique
  ON public.family_invitations (family_id, LOWER(email))
  WHERE accepted_at IS NULL;

ALTER TABLE public.family_invitations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.family_invitations FORCE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.is_family_manager(target_family_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.family_members member
    WHERE member.family_id = target_family_id
      AND member.user_id = public.current_user_id()
      AND member.role IN ('owner', 'admin')
  );
$$;

DROP POLICY IF EXISTS family_invitations_select_manager ON public.family_invitations;
CREATE POLICY family_invitations_select_manager
  ON public.family_invitations
  FOR SELECT
  USING (public.is_family_manager(family_id));

DROP POLICY IF EXISTS family_invitations_insert_manager ON public.family_invitations;
CREATE POLICY family_invitations_insert_manager
  ON public.family_invitations
  FOR INSERT
  WITH CHECK (
    public.is_family_manager(family_id)
    AND invited_by = public.current_user_id()
  );

DROP POLICY IF EXISTS family_invitations_update_manager ON public.family_invitations;
CREATE POLICY family_invitations_update_manager
  ON public.family_invitations
  FOR UPDATE
  USING (public.is_family_manager(family_id) AND accepted_at IS NULL)
  WITH CHECK (public.is_family_manager(family_id) AND accepted_at IS NULL);

DROP POLICY IF EXISTS family_invitations_delete_manager ON public.family_invitations;
CREATE POLICY family_invitations_delete_manager
  ON public.family_invitations
  FOR DELETE
  USING (public.is_family_manager(family_id));

-- Не приглашать того, кто уже в семье. profiles чужих скрыты RLS, поэтому
-- проверка -- SECURITY DEFINER; чтобы функция не превращалась в способ
-- узнавать, чей адрес зарегистрирован, она отвечает только менеджеру семьи.
CREATE OR REPLACE FUNCTION public.is_family_member_email(
  target_family_id uuid,
  p_email text
)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT public.is_family_manager(target_family_id)
    AND EXISTS (
      SELECT 1
      FROM public.family_members member
      JOIN public.profiles profile ON profile.id = member.user_id
      WHERE member.family_id = target_family_id
        AND profile.email = LOWER(TRIM(p_email))
    );
$$;

-- Воркер: токен создаётся в момент отправки письма. Повторная отправка
-- заменяет прежний токен и продлевает срок.
CREATE OR REPLACE FUNCTION public.create_family_invitation_token(
  p_invitation_id uuid,
  p_token_hash text,
  p_expires_at timestamptz
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  updated integer;
BEGIN
  UPDATE public.family_invitations
  SET token_hash = p_token_hash, expires_at = p_expires_at
  WHERE id = p_invitation_id AND accepted_at IS NULL;
  GET DIAGNOSTICS updated = ROW_COUNT;
  RETURN updated > 0;
END;
$$;

-- Воркер: данные для письма. Пусто, если приглашение уже принято или
-- отозвано (строка удалена).
CREATE OR REPLACE FUNCTION public.get_family_invitation_mail_info_system(p_invitation_id uuid)
RETURNS TABLE (email text, family_name text, inviter_name text)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT
    invitation.email,
    family.name::text,
    COALESCE(NULLIF(inviter.display_name, ''), inviter.email)::text
  FROM public.family_invitations invitation
  JOIN public.families family ON family.id = invitation.family_id
  JOIN public.profiles inviter ON inviter.id = invitation.invited_by
  WHERE invitation.id = p_invitation_id AND invitation.accepted_at IS NULL;
$$;

-- Страница приглашения показывает, куда зовут, ещё до входа: токен секретен,
-- название семьи и имя пригласившего по нему раскрывать не страшно.
CREATE OR REPLACE FUNCTION public.preview_family_invitation(p_token_hash text)
RETURNS TABLE (family_name text, inviter_name text)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT
    family.name::text,
    COALESCE(NULLIF(inviter.display_name, ''), inviter.email)::text
  FROM public.family_invitations invitation
  JOIN public.families family ON family.id = invitation.family_id
  JOIN public.profiles inviter ON inviter.id = invitation.invited_by
  WHERE invitation.token_hash = p_token_hash
    AND invitation.accepted_at IS NULL
    AND invitation.expires_at > NOW();
$$;

-- Принять приглашение вызывающим пользователем. Пусто для неверного,
-- просроченного или уже принятого токена. Если человек уже в семье, всё
-- равно погашает приглашение и возвращает семью (событие о вступлении при
-- этом не рассылается -- ничего не изменилось).
CREATE OR REPLACE FUNCTION public.accept_family_invitation(p_token_hash text)
RETURNS TABLE (family_id uuid, family_name text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  caller uuid := public.current_user_id();
  invitation public.family_invitations;
  family_title text;
  caller_name text;
  added integer;
BEGIN
  IF caller IS NULL THEN
    RAISE EXCEPTION 'authentication required';
  END IF;

  UPDATE public.family_invitations
  SET accepted_at = NOW(), accepted_by = caller
  WHERE token_hash = p_token_hash
    AND accepted_at IS NULL
    AND expires_at > NOW()
  RETURNING * INTO invitation;

  IF invitation.id IS NULL THEN
    RETURN;
  END IF;

  INSERT INTO public.family_members (family_id, user_id, role)
  VALUES (invitation.family_id, caller, 'member')
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS added = ROW_COUNT;

  SELECT name::text INTO family_title FROM public.families WHERE id = invitation.family_id;

  IF added > 0 THEN
    SELECT COALESCE(NULLIF(profile.display_name, ''), profile.email)
    INTO caller_name
    FROM public.profiles profile WHERE profile.id = caller;

    INSERT INTO public.outbox_events (aggregate_type, aggregate_id, event_type, payload)
    VALUES (
      'family',
      invitation.family_id,
      'family.member.joined',
      jsonb_build_object(
        'familyId', invitation.family_id,
        'userId', caller,
        'role', 'member',
        'displayName', caller_name
      )
    );
  END IF;

  RETURN QUERY SELECT invitation.family_id, family_title;
END;
$$;

-- ---------------------------------------------------------------------
-- Welcome-письмо.
-- ---------------------------------------------------------------------

-- Подтверждение email: как в 0031, плюс welcome при первом подтверждении.
CREATE OR REPLACE FUNCTION public.verify_email_with_token(p_token_hash text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  consumed_user uuid;
  was_verified boolean;
BEGIN
  UPDATE public.email_tokens
  SET used_at = NOW()
  WHERE token_hash = p_token_hash
    AND kind = 'verify_email'
    AND used_at IS NULL
    AND expires_at > NOW()
  RETURNING user_id INTO consumed_user;

  IF consumed_user IS NULL THEN
    RETURN false;
  END IF;

  SELECT email_verified_at IS NOT NULL INTO was_verified
  FROM public.profiles WHERE id = consumed_user;

  UPDATE public.profiles
  SET email_verified_at = COALESCE(email_verified_at, NOW()),
      updated_at = NOW()
  WHERE id = consumed_user;

  IF NOT COALESCE(was_verified, true) THEN
    INSERT INTO public.outbox_events (aggregate_type, aggregate_id, event_type, payload)
    VALUES (
      'profile',
      consumed_user,
      'email.welcome',
      jsonb_build_object('userId', consumed_user)
    );
  END IF;

  RETURN true;
END;
$$;

-- Вход через GitHub: как в 0031, плюс welcome для впервые созданного
-- аккаунта (повторный вход тем же адресом письма не шлёт).
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
  normalized_email text := LOWER(TRIM(p_email));
  already_existed boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM public.profiles WHERE profiles.email = normalized_email
  ) INTO already_existed;

  INSERT INTO public.profiles (email, display_name, email_verified_at)
  VALUES (normalized_email, NULLIF(TRIM(p_display_name), ''), NOW())
  ON CONFLICT ON CONSTRAINT profiles_email_key DO UPDATE
  SET display_name = COALESCE(EXCLUDED.display_name, public.profiles.display_name),
      email_verified_at = COALESCE(public.profiles.email_verified_at, NOW()),
      updated_at = NOW()
  RETURNING * INTO created_profile;

  PERFORM public.prune_user_sessions(created_profile.id);

  INSERT INTO public.app_sessions (token_hash, user_id, expires_at)
  VALUES (p_token_hash, created_profile.id, p_expires_at);

  IF NOT already_existed THEN
    INSERT INTO public.outbox_events (aggregate_type, aggregate_id, event_type, payload)
    VALUES (
      'profile',
      created_profile.id,
      'email.welcome',
      jsonb_build_object('userId', created_profile.id)
    );
  END IF;

  RETURN QUERY
  SELECT
    created_profile.id AS user_id,
    created_profile.email AS email,
    created_profile.display_name AS display_name;
END;
$$;
