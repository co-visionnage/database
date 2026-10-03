-- =========================================================================
-- 037: настройки уведомлений (push и почта по типам событий) и отписка
--
-- Раньше любое событие семьи уходило всем подписанным устройствам и всем
-- подтверждённым адресам без права отказаться. Теперь у человека есть
-- настройки по категориям: отдельно push и отдельно почта.
--
-- Нет строки -- действуют значения по умолчанию: push включён везде, почта
-- только там, где письма и были (новый сериал, новый сезон, напоминание).
-- Остальные категории письмами пока не рассылаются, их почтовый флаг по
-- умолчанию выключен.
--
-- Транзакционные письма (подтверждение, сброс пароля, безопасность,
-- приглашение) сюда не входят: от них отказаться нельзя.
-- =========================================================================

CREATE TABLE IF NOT EXISTS public.notification_preferences (
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  category text NOT NULL CHECK (category IN (
    'series_added',
    'series_watched',
    'series_rated',
    'season_update',
    'progress_reminder',
    'poll',
    'watch_event',
    'member_joined'
  )),
  push boolean NOT NULL DEFAULT true,
  email boolean NOT NULL DEFAULT false,
  updated_at timestamptz NOT NULL DEFAULT NOW(),
  PRIMARY KEY (user_id, category)
);

ALTER TABLE public.notification_preferences ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notification_preferences FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS notification_preferences_owner ON public.notification_preferences;
CREATE POLICY notification_preferences_owner
  ON public.notification_preferences
  FOR ALL
  USING (user_id = public.current_user_id())
  WITH CHECK (user_id = public.current_user_id());

-- Значение по умолчанию для канала категории. Единое место, чтобы список
-- «почта включена по умолчанию» не расходился между функциями.
CREATE OR REPLACE FUNCTION public.notification_default(p_category text, p_channel text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE p_channel
    WHEN 'email' THEN p_category IN ('series_added', 'season_update', 'progress_reminder')
    ELSE true
  END;
$$;

CREATE OR REPLACE FUNCTION public.notification_enabled(
  p_user_id uuid,
  p_category text,
  p_channel text
)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT COALESCE(
    (
      SELECT CASE p_channel WHEN 'push' THEN pref.push ELSE pref.email END
      FROM public.notification_preferences pref
      WHERE pref.user_id = p_user_id AND pref.category = p_category
    ),
    public.notification_default(p_category, p_channel)
  );
$$;

-- Push-подписки с учётом настроек категории. Старые функции без категории
-- (0010, 0028) остаются как есть, но воркер использует эти.
CREATE OR REPLACE FUNCTION public.get_family_push_subscriptions_for_category_system(
  target_family_id uuid,
  exclude_user_id uuid,
  p_category text
)
RETURNS TABLE (endpoint text, p256dh text, auth text)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT sub.endpoint, sub.p256dh, sub.auth
  FROM public.push_subscriptions sub
  JOIN public.family_members member ON member.user_id = sub.user_id
  WHERE member.family_id = target_family_id
    AND (exclude_user_id IS NULL OR sub.user_id <> exclude_user_id)
    AND public.notification_enabled(sub.user_id, p_category, 'push');
$$;

CREATE OR REPLACE FUNCTION public.get_user_push_subscriptions_for_category_system(
  target_user_id uuid,
  p_category text
)
RETURNS TABLE (endpoint text, p256dh text, auth text)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT sub.endpoint, sub.p256dh, sub.auth
  FROM public.push_subscriptions sub
  WHERE sub.user_id = target_user_id
    AND public.notification_enabled(sub.user_id, p_category, 'push');
$$;

-- Адресаты писем семье: подтверждённые адреса (0031) плюс настройки
-- категории. Заменяет версию без категории из 0031.
DROP FUNCTION IF EXISTS public.get_family_member_mail_info_system(uuid, uuid);

CREATE OR REPLACE FUNCTION public.get_family_member_mail_info_system(
  target_family_id uuid,
  exclude_user_id uuid,
  p_category text
)
RETURNS TABLE (user_id uuid, email text, display_name text)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT profile.id, profile.email, profile.display_name::text
  FROM public.family_members member
  JOIN public.profiles profile ON profile.id = member.user_id
  WHERE member.family_id = target_family_id
    AND profile.email_verified_at IS NOT NULL
    AND (exclude_user_id IS NULL OR member.user_id <> exclude_user_id)
    AND public.notification_enabled(profile.id, p_category, 'email');
$$;

-- Отписка по ссылке из письма: сессии нет, пользователь и категория
-- известны из подписанного токена. Меняет только почтовый канал категории,
-- push не трогает.
CREATE OR REPLACE FUNCTION public.set_email_preference_system(
  p_user_id uuid,
  p_category text,
  p_enabled boolean
)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  INSERT INTO public.notification_preferences (user_id, category, push, email)
  VALUES (
    p_user_id,
    p_category,
    public.notification_enabled(p_user_id, p_category, 'push'),
    p_enabled
  )
  ON CONFLICT (user_id, category) DO UPDATE
  SET email = EXCLUDED.email, updated_at = NOW();
$$;
