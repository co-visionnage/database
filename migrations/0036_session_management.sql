-- =========================================================================
-- 036: управление сессиями и смена пароля из аккаунта
--
-- До сих пор пароль можно было только сбросить письмом, а сессии были
-- невидимы: ни списка устройств, ни способа выйти с чужого. Теперь:
--
--   * app_sessions хранит IP, User-Agent и время последней активности;
--   * get_session_user обновляет last_seen_at не чаще раза в 5 минут (иначе
--     каждый запрос превращался бы в запись);
--   * change_my_password меняет пароль, закрывает остальные сессии и
--     кладёт событие для письма-уведомления -- атомарно.
--
-- Список сессий и отзыв идут прямыми запросами под пользовательским
-- контекстом: политика app_sessions_owner_only уже ограничивает их своими
-- строками.
-- =========================================================================

ALTER TABLE public.app_sessions
  ADD COLUMN IF NOT EXISTS ip text,
  ADD COLUMN IF NOT EXISTS user_agent text,
  ADD COLUMN IF NOT EXISTS last_seen_at timestamptz;

UPDATE public.app_sessions SET last_seen_at = created_at WHERE last_seen_at IS NULL;

-- До этой миграции вход закрывал все остальные сессии пользователя: на
-- втором устройстве первое выкидывало, и список сессий состоял бы всегда из
-- одной строки. Теперь сессии сосуществуют; чистятся только истёкшие и
-- самые старые сверх лимита (20 на пользователя), чтобы таблица не росла от
-- бесконечных входов.
CREATE OR REPLACE FUNCTION public.prune_user_sessions(p_user_id uuid)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  DELETE FROM public.app_sessions
  WHERE user_id = p_user_id AND expires_at <= NOW();

  DELETE FROM public.app_sessions
  WHERE id IN (
    SELECT id FROM public.app_sessions
    WHERE user_id = p_user_id
    ORDER BY COALESCE(last_seen_at, created_at) DESC
    OFFSET 19
  );
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

  PERFORM public.prune_user_sessions(p_user_id);

  INSERT INTO public.app_sessions (token_hash, user_id, expires_at)
  VALUES (p_token_hash, p_user_id, p_expires_at);

  RETURN QUERY
  SELECT
    target_profile.id AS user_id,
    target_profile.email AS email,
    target_profile.display_name AS display_name;
END;
$$;

CREATE OR REPLACE FUNCTION public.set_session_metadata(
  p_token_hash text,
  p_ip text,
  p_user_agent text
)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  UPDATE public.app_sessions
  SET ip = LEFT(NULLIF(p_ip, ''), 64),
      user_agent = LEFT(NULLIF(p_user_agent, ''), 512),
      last_seen_at = NOW()
  WHERE token_hash = p_token_hash;
$$;

CREATE OR REPLACE FUNCTION public.get_session_user(p_token_hash text)
RETURNS TABLE (
  session_id uuid,
  user_id uuid,
  email text,
  display_name varchar(50),
  expires_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.app_sessions AS touched
  SET last_seen_at = NOW()
  WHERE touched.token_hash = p_token_hash
    AND touched.expires_at > NOW()
    AND (touched.last_seen_at IS NULL OR touched.last_seen_at < NOW() - INTERVAL '5 minutes');

  RETURN QUERY
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
END;
$$;

-- Смена пароля вызывающего пользователя. Текущий пароль проверяет
-- приложение (хэш scrypt считается в Go) до вызова. Закрывает все сессии,
-- кроме текущей, и гасит 2FA-challenge'ы: украденный ранее сеанс не должен
-- пережить смену пароля. Возвращает число закрытых сессий.
CREATE OR REPLACE FUNCTION public.change_my_password(
  p_new_password_hash text,
  p_keep_session_id uuid
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  caller uuid := public.current_user_id();
  revoked integer;
BEGIN
  IF caller IS NULL THEN
    RAISE EXCEPTION 'authentication required';
  END IF;

  UPDATE public.profiles
  SET password_hash = p_new_password_hash, updated_at = NOW()
  WHERE id = caller;

  DELETE FROM public.app_sessions
  WHERE user_id = caller AND id <> p_keep_session_id;
  GET DIAGNOSTICS revoked = ROW_COUNT;

  DELETE FROM public.two_factor_challenges WHERE user_id = caller;

  INSERT INTO public.outbox_events (aggregate_type, aggregate_id, event_type, payload)
  VALUES (
    'profile',
    caller,
    'security.password_changed',
    jsonb_build_object('userId', caller)
  );

  RETURN revoked;
END;
$$;
