-- =========================================================================
-- 040: еженедельная сводка семьи по почте
--
-- Раз в неделю человек получает одно письмо: что за последние семь дней
-- добавили в списки его семей, что досмотрели, какие встречи запланированы
-- и у каких сериалов скоро выходят новые серии.
--
-- Это обычная категория уведомлений (можно отказаться в настройках и по
-- ссылке из письма), письма включены по умолчанию. Push для неё не
-- имеет смысла, поэтому в настройках этот канал не показывается.
-- =========================================================================

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
    'member_joined',
    'weekly_digest'
  ));

CREATE OR REPLACE FUNCTION public.notification_default(p_category text, p_channel text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE p_channel
    WHEN 'email' THEN p_category IN ('series_added', 'season_update', 'progress_reminder', 'weekly_digest')
    ELSE true
  END;
$$;

-- Какие недели уже разосланы. Один ключ ('2026-W41') на неделю: несколько
-- экземпляров API или перезапуск посреди рассылки не разошлют её дважды.
CREATE TABLE IF NOT EXISTS public.digest_runs (
  week_key text PRIMARY KEY,
  started_at timestamptz NOT NULL DEFAULT NOW()
);

ALTER TABLE public.digest_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.digest_runs FORCE ROW LEVEL SECURITY;
-- Политик нет намеренно: читают и пишут только функции ниже (SECURITY DEFINER).

-- true -- эту неделю застолбили мы и рассылку делать нам; false -- уже
-- застолблена (кем-то ещё или раньше).
CREATE OR REPLACE FUNCTION public.claim_weekly_digest(p_week_key text)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  WITH claimed AS (
    INSERT INTO public.digest_runs (week_key)
    VALUES (p_week_key)
    ON CONFLICT (week_key) DO NOTHING
    RETURNING 1
  )
  SELECT EXISTS (SELECT 1 FROM claimed);
$$;

-- Кому слать: подтверждённый адрес, включённая почта для категории и
-- хотя бы одна семья (без семьи рассказывать нечего).
CREATE OR REPLACE FUNCTION public.list_weekly_digest_recipients_system()
RETURNS TABLE (user_id uuid)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT profile.id
  FROM public.profiles profile
  WHERE profile.email_verified_at IS NOT NULL
    AND EXISTS (SELECT 1 FROM public.family_members member WHERE member.user_id = profile.id)
    AND public.notification_enabled(profile.id, 'weekly_digest', 'email');
$$;

-- Содержимое сводки для одного человека по всем его семьям. Каждая строка --
-- один пункт: section ('added', 'watched', 'event', 'airing'), название,
-- пояснение и момент. По каждому разделу семьи отдаётся не больше 10
-- пунктов, самые свежие (для 'event' и 'airing' -- ближайшие).
CREATE OR REPLACE FUNCTION public.get_weekly_digest_system(
  p_user_id uuid,
  p_since timestamptz,
  p_until timestamptz
)
RETURNS TABLE (
  family_id uuid,
  family_name text,
  section text,
  title text,
  detail text,
  happened_at timestamptz
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  WITH my_families AS (
    SELECT family.id, family.name::text AS name
    FROM public.family_members member
    JOIN public.families family ON family.id = member.family_id
    WHERE member.user_id = p_user_id
  ),
  items AS (
    -- Добавили в список за период.
    SELECT f.id AS fid, f.name AS fname, 'added'::text AS section,
           s.title::text AS title,
           COALESCE(NULLIF(author.display_name, ''), author.email)::text AS detail,
           s.created_at AS at,
           s.created_at AS sort_key
    FROM my_families f
    JOIN public.family_series s ON s.family_id = f.id
    JOIN public.profiles author ON author.id = s.created_by
    WHERE s.created_at >= p_since AND s.created_at < p_until

    UNION ALL

    -- Посмотрели за период (кто и с какой оценкой).
    SELECT f.id, f.name, 'watched',
           s.title::text,
           COALESCE(NULLIF(viewer.display_name, ''), viewer.email)::text
             || COALESCE(' · ' || st.rating::text || '/5', ''),
           st.watched_at,
           st.watched_at
    FROM my_families f
    JOIN public.family_series s ON s.family_id = f.id
    JOIN public.family_series_status st ON st.series_id = s.id AND st.status = 'watched'
    JOIN public.profiles viewer ON viewer.id = st.user_id
    WHERE st.watched_at >= p_since AND st.watched_at < p_until

    UNION ALL

    -- Встречи на ближайшую неделю.
    SELECT f.id, f.name, 'event',
           e.title::text,
           COALESCE(s.title::text, ''),
           e.scheduled_at,
           e.scheduled_at
    FROM my_families f
    JOIN public.family_watch_events e ON e.family_id = f.id
    LEFT JOIN public.family_series s ON s.id = e.series_id
    WHERE e.scheduled_at >= p_until AND e.scheduled_at < p_until + interval '7 days'

    UNION ALL

    -- Скоро выходят новые серии у сериалов, которые этот человек ещё не
    -- досмотрел.
    SELECT f.id, f.name, 'airing',
           s.title::text,
           COALESCE(s.next_episode_label::text, ''),
           s.next_episode_air_date::timestamptz,
           s.next_episode_air_date::timestamptz
    FROM my_families f
    JOIN public.family_series s ON s.family_id = f.id
    LEFT JOIN public.family_series_status st ON st.series_id = s.id AND st.user_id = p_user_id
    WHERE s.next_episode_air_date >= p_until::date
      AND s.next_episode_air_date < (p_until + interval '7 days')::date
      AND COALESCE(st.status, 'to-watch') <> 'watched'
  ),
  ranked AS (
    SELECT items.*,
           row_number() OVER (
             PARTITION BY fid, section
             ORDER BY CASE WHEN section IN ('event', 'airing') THEN sort_key END ASC,
                      CASE WHEN section IN ('added', 'watched') THEN sort_key END DESC
           ) AS position
    FROM items
  )
  SELECT ranked.fid, ranked.fname, ranked.section, ranked.title, ranked.detail, ranked.at
  FROM ranked
  WHERE ranked.position <= 10
  ORDER BY ranked.fname, ranked.fid,
           CASE ranked.section WHEN 'added' THEN 1 WHEN 'watched' THEN 2 WHEN 'event' THEN 3 ELSE 4 END,
           ranked.at;
$$;
