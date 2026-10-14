-- =========================================================================
-- 041: напоминание о встрече для просмотра
--
-- За час (по умолчанию) до начала встречи каждый участник семьи, кто не
-- ответил «нет», получает push и письмо. Встреча напоминает о себе один
-- раз: reminded_at ставится тем же UPDATE, который выбирает встречи, поэтому
-- перезапуск API или несколько его экземпляров напоминание не удваивают.
--
-- Если встречу создали уже внутри окна напоминания («через полчаса
-- смотрим»), напоминать не нужно: все только что о ней узнали.
-- =========================================================================

ALTER TABLE public.family_watch_events
  ADD COLUMN IF NOT EXISTS reminded_at timestamptz;

-- Только ещё не напомненные встречи: индекс остаётся маленьким.
CREATE INDEX IF NOT EXISTS family_watch_events_due_reminder_index
  ON public.family_watch_events (scheduled_at)
  WHERE reminded_at IS NULL;

ALTER TABLE public.notification_preferences
  DROP CONSTRAINT IF EXISTS notification_preferences_category_check;

ALTER TABLE public.notification_preferences
  ADD CONSTRAINT notification_preferences_category_check CHECK (category IN (
    'series_added',
    'series_watched',
    'series_rated',
    'season_update',
    'progress_reminder',
    'poll',
    'watch_event',
    'event_reminder',
    'member_joined',
    'weekly_digest'
  ));

-- Почта по умолчанию включена: напоминание ждут, и оно редкое. Push включён
-- у всех категорий.
CREATE OR REPLACE FUNCTION public.notification_default(p_category text, p_channel text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE p_channel
    WHEN 'email' THEN p_category IN (
      'series_added', 'season_update', 'progress_reminder', 'weekly_digest', 'event_reminder'
    )
    ELSE true
  END;
$$;

-- Атомарно забирает встречи, до начала которых осталось не больше p_lead, и
-- возвращает по строке на каждого, кому напомнить: участники семьи, кроме
-- ответивших «нет». Уже начавшиеся встречи не трогаются.
CREATE OR REPLACE FUNCTION public.claim_event_reminders_system(p_lead interval)
RETURNS TABLE (
  event_id uuid,
  family_id uuid,
  user_id uuid,
  title text,
  scheduled_at timestamptz
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  WITH due AS (
    UPDATE public.family_watch_events event
    SET reminded_at = NOW()
    WHERE event.reminded_at IS NULL
      AND event.scheduled_at > NOW()
      AND event.scheduled_at <= NOW() + p_lead
      AND event.created_at <= event.scheduled_at - p_lead
    RETURNING event.id, event.family_id, event.title, event.scheduled_at
  )
  SELECT due.id, due.family_id, member.user_id, due.title::text, due.scheduled_at
  FROM due
  JOIN public.family_members member ON member.family_id = due.family_id
  LEFT JOIN public.family_watch_event_rsvps rsvp
    ON rsvp.event_id = due.id AND rsvp.user_id = member.user_id
  WHERE COALESCE(rsvp.status, 'maybe') <> 'no';
$$;
