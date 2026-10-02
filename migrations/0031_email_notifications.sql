-- =========================================================================
-- 031: подтверждение email, сброс пароля и данные для писем
--
-- До этой миграции в приложении не было ни подтверждения email, ни сброса
-- пароля: регистрация сразу выдавала сессию, а владелец чужого адреса,
-- занятого кем-то другим, не мог ни зарегистрироваться (ACCOUNT_ALREADY_EXISTS,
-- см. 0023), ни вернуть доступ. Теперь:
--
--   * profiles.email_verified_at -- когда владение адресом подтверждено;
--   * email_tokens -- одноразовые токены подтверждения и сброса. Хранится
--     только SHA-256 токена, сам токен знает лишь получатель письма. RLS
--     включена без единой политики: роль app_user не читает и не пишет
--     таблицу напрямую, только через SECURITY DEFINER функции ниже;
--   * события для писем кладутся в outbox_events (тот же transactional
--     outbox, что и остальные события) прямо из SQL-функций, поэтому
--     «аккаунт создан» и «письмо поставлено в очередь» атомарны.
--
-- Токены создаёт не API, а notrecinema-worker: в outbox и в NATS попадает
-- только user id, а сам токен рождается в момент отправки письма и нигде,
-- кроме письма, не светится.
--
-- Существующие аккаунты считаются подтверждёнными: они уже получали письма
-- и пользовались сервисом до этой миграции, а подтверждение вводится для
-- новых регистраций. Письма-уведомления идут только на подтверждённые
-- адреса -- иначе зарегистрировавшийся на чужой email спамил бы владельцу
-- уведомлениями своей семьи.
-- =========================================================================

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS email_verified_at timestamptz;

UPDATE public.profiles
SET email_verified_at = created_at
WHERE email_verified_at IS NULL;

CREATE TABLE IF NOT EXISTS public.email_tokens (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  kind text NOT NULL CHECK (kind IN ('verify_email', 'reset_password')),
  token_hash text UNIQUE NOT NULL,
  expires_at timestamptz NOT NULL,
  used_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS email_tokens_user_kind_index
  ON public.email_tokens (user_id, kind);

ALTER TABLE public.email_tokens ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------
-- Регистрация: то же, что в 0023, плюс событие «нужно подтвердить email».
-- ---------------------------------------------------------------------
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

  INSERT INTO public.outbox_events (aggregate_type, aggregate_id, event_type, payload)
  VALUES (
    'profile',
    created_profile.id,
    'email.verification_requested',
    jsonb_build_object('userId', created_profile.id)
  );

  RETURN QUERY
  SELECT
    created_profile.id AS user_id,
    created_profile.email AS email,
    created_profile.display_name AS display_name;
END;
$$;

-- ---------------------------------------------------------------------
-- Вход через внешнего провайдера (сейчас только GitHub): адрес уже
-- подтверждён самим провайдером (internal/oauth берёт только verified email),
-- поэтому профиль сразу помечается подтверждённым.
-- ---------------------------------------------------------------------
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
  INSERT INTO public.profiles (email, display_name, email_verified_at)
  VALUES (LOWER(TRIM(p_email)), NULLIF(TRIM(p_display_name), ''), NOW())
  ON CONFLICT ON CONSTRAINT profiles_email_key DO UPDATE
  SET display_name = COALESCE(EXCLUDED.display_name, public.profiles.display_name),
      email_verified_at = COALESCE(public.profiles.email_verified_at, NOW()),
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

-- ---------------------------------------------------------------------
-- Запрос сброса пароля. Ничего не возвращает: вызывающий всегда отвечает
-- клиенту одинаково, независимо от того, есть ли такой email -- иначе
-- форма сброса стала бы способом проверять, кто зарегистрирован.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.request_password_reset(p_email text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  target_id uuid;
BEGIN
  SELECT id INTO target_id
  FROM public.profiles
  WHERE email = LOWER(TRIM(p_email));

  IF target_id IS NULL THEN
    RETURN;
  END IF;

  INSERT INTO public.outbox_events (aggregate_type, aggregate_id, event_type, payload)
  VALUES (
    'profile',
    target_id,
    'email.password_reset_requested',
    jsonb_build_object('userId', target_id)
  );
END;
$$;

-- ---------------------------------------------------------------------
-- Токены. create_email_token вызывает notrecinema-worker в момент отправки
-- письма; прежние неиспользованные токены того же вида для этого
-- пользователя гасятся, поэтому «действует» всегда только последняя ссылка.
-- Как и остальные *_system функции, доступна роли app_user для любого
-- user id: токен бесполезен без знания его прообраза, а он существует
-- только в письме.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_email_token(
  p_user_id uuid,
  p_kind text,
  p_token_hash text,
  p_expires_at timestamptz
)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  DELETE FROM public.email_tokens
  WHERE user_id = p_user_id AND kind = p_kind AND used_at IS NULL;

  INSERT INTO public.email_tokens (user_id, kind, token_hash, expires_at)
  VALUES (p_user_id, p_kind, p_token_hash, p_expires_at);
$$;

CREATE OR REPLACE FUNCTION public.verify_email_with_token(p_token_hash text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  consumed_user uuid;
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

  UPDATE public.profiles
  SET email_verified_at = COALESCE(email_verified_at, NOW()),
      updated_at = NOW()
  WHERE id = consumed_user;

  RETURN true;
END;
$$;

-- Сброс пароля по токену: гасит токен, ставит новый хэш, считает email
-- подтверждённым (получатель письма им владеет), разлогинивает везде и
-- кладёт событие для письма-уведомления. 2FA не обходится: после сброса
-- вход по-прежнему требует TOTP-код. Возвращает id пользователя или NULL,
-- если токен неверный, истёк или уже использован.
CREATE OR REPLACE FUNCTION public.reset_password_with_token(
  p_token_hash text,
  p_password_hash text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  consumed_user uuid;
BEGIN
  UPDATE public.email_tokens
  SET used_at = NOW()
  WHERE token_hash = p_token_hash
    AND kind = 'reset_password'
    AND used_at IS NULL
    AND expires_at > NOW()
  RETURNING user_id INTO consumed_user;

  IF consumed_user IS NULL THEN
    RETURN NULL;
  END IF;

  UPDATE public.profiles
  SET password_hash = p_password_hash,
      email_verified_at = COALESCE(email_verified_at, NOW()),
      updated_at = NOW()
  WHERE id = consumed_user;

  DELETE FROM public.app_sessions WHERE user_id = consumed_user;
  DELETE FROM public.two_factor_challenges WHERE user_id = consumed_user;
  DELETE FROM public.email_tokens
  WHERE user_id = consumed_user AND kind = 'reset_password';

  INSERT INTO public.outbox_events (aggregate_type, aggregate_id, event_type, payload)
  VALUES (
    'profile',
    consumed_user,
    'security.password_changed',
    jsonb_build_object('userId', consumed_user)
  );

  RETURN consumed_user;
END;
$$;

-- ---------------------------------------------------------------------
-- Данные для писем (читает воркер, у которого нет пользовательского
-- контекста -- как и у остальных *_system функций).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_user_mail_info_system(target_user_id uuid)
RETURNS TABLE (email text, display_name text, email_verified boolean)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT
    profile.email,
    profile.display_name::text,
    profile.email_verified_at IS NOT NULL
  FROM public.profiles profile
  WHERE profile.id = target_user_id;
$$;

-- Только подтверждённые адреса. NULL в exclude_user_id -- «никого не
-- исключать» (фоновые проверки без актора), как в 0028.
CREATE OR REPLACE FUNCTION public.get_family_member_mail_info_system(
  target_family_id uuid,
  exclude_user_id uuid
)
RETURNS TABLE (email text, display_name text)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT profile.email, profile.display_name::text
  FROM public.family_members member
  JOIN public.profiles profile ON profile.id = member.user_id
  WHERE member.family_id = target_family_id
    AND profile.email_verified_at IS NOT NULL
    AND (exclude_user_id IS NULL OR member.user_id <> exclude_user_id);
$$;
