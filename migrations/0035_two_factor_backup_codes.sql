-- =========================================================================
-- 035: резервные коды двухфакторной аутентификации
--
-- Потерял телефон с аутентификатором -- аккаунт закрыт навсегда: TOTP-секрет
-- был единственным способом пройти второй фактор. Резервные коды -- второй
-- путь: при включении 2FA человеку один раз показывают набор одноразовых
-- кодов, любой из них заменяет TOTP-код при входе.
--
-- В БД лежат только медленные хэши (scrypt, как у паролей), считает их
-- приложение: коды короткие (~50 бит), быстрый хэш при утечке базы
-- подбирался бы офлайн. Поэтому сверка идёт в Go: функция отдаёт
-- неиспользованные хэши пользователя, приложение находит совпавший, а
-- use_two_factor_backup_code атомарно гасит именно эту строку (двое
-- одновременных входов с одним кодом не пройдут оба).
--
-- RLS включена без политик: роль app_user работает с таблицей только через
-- SECURITY DEFINER функции ниже.
-- =========================================================================

CREATE TABLE IF NOT EXISTS public.two_factor_backup_codes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  code_hash text NOT NULL,
  used_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS two_factor_backup_codes_unused_index
  ON public.two_factor_backup_codes (user_id)
  WHERE used_at IS NULL;

ALTER TABLE public.two_factor_backup_codes ENABLE ROW LEVEL SECURITY;

-- Заменяет весь набор кодов вызывающего пользователя (сессия обязательна:
-- вызывается внутри транзакции с app.current_user_id). Старые коды,
-- использованные и нет, перестают работать.
CREATE OR REPLACE FUNCTION public.replace_two_factor_backup_codes(p_code_hashes text[])
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  caller uuid := public.current_user_id();
BEGIN
  IF caller IS NULL THEN
    RAISE EXCEPTION 'authentication required';
  END IF;

  DELETE FROM public.two_factor_backup_codes WHERE user_id = caller;

  INSERT INTO public.two_factor_backup_codes (user_id, code_hash)
  SELECT caller, code_hash FROM unnest(p_code_hashes) AS code_hash;
END;
$$;

CREATE OR REPLACE FUNCTION public.delete_my_two_factor_backup_codes()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  DELETE FROM public.two_factor_backup_codes
  WHERE user_id = public.current_user_id();
$$;

CREATE OR REPLACE FUNCTION public.count_my_two_factor_backup_codes()
RETURNS integer
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT COUNT(*)::integer
  FROM public.two_factor_backup_codes
  WHERE user_id = public.current_user_id()
    AND used_at IS NULL;
$$;

-- Для входа: сессии ещё нет, пользователь известен по challenge-токену, а не
-- по app.current_user_id.
CREATE OR REPLACE FUNCTION public.get_two_factor_backup_code_hashes(p_user_id uuid)
RETURNS TABLE (id uuid, code_hash text)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT code.id, code.code_hash
  FROM public.two_factor_backup_codes code
  WHERE code.user_id = p_user_id AND code.used_at IS NULL;
$$;

-- Гасит ровно один код и возвращает, сколько их осталось. -1 -- код уже был
-- использован (гонка двух входов). Событие для письма-уведомления кладётся
-- здесь же: «код потрачен» и «письмо поставлено в очередь» атомарны.
CREATE OR REPLACE FUNCTION public.use_two_factor_backup_code(p_code_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  owner_id uuid;
  remaining integer;
BEGIN
  UPDATE public.two_factor_backup_codes
  SET used_at = NOW()
  WHERE id = p_code_id AND used_at IS NULL
  RETURNING user_id INTO owner_id;

  IF owner_id IS NULL THEN
    RETURN -1;
  END IF;

  SELECT COUNT(*)::integer INTO remaining
  FROM public.two_factor_backup_codes
  WHERE user_id = owner_id AND used_at IS NULL;

  INSERT INTO public.outbox_events (aggregate_type, aggregate_id, event_type, payload)
  VALUES (
    'profile',
    owner_id,
    'security.backup_code_used',
    jsonb_build_object('userId', owner_id, 'remaining', remaining)
  );

  RETURN remaining;
END;
$$;
