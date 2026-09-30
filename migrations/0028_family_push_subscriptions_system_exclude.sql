-- notrecinema-worker уведомляет семью о событии, но не самого автора
-- события (не нужно говорить человеку "кто-то посмотрел сериал", если
-- это сделал он сам). get_family_push_subscriptions_system (миграция
-- 0010) такого исключения не делает и не может -- у воркера нет
-- app.current_user_id, а значит не подходит и обычный
-- get_family_push_subscriptions с его is_family_member(current_user_id())
-- (миграция 0007). Нужен третий вариант: SECURITY DEFINER, без RLS-
-- зависимости от вызывающего, но с явным exclude_user_id параметром.

CREATE OR REPLACE FUNCTION public.get_family_push_subscriptions_system(
  target_family_id uuid,
  exclude_user_id uuid
)
RETURNS TABLE (endpoint text, p256dh text, auth text)
LANGUAGE sql
SECURITY DEFINER
STABLE
AS $$
  SELECT sub.endpoint, sub.p256dh, sub.auth
  FROM public.push_subscriptions sub
  JOIN public.family_members member ON member.user_id = sub.user_id
  WHERE member.family_id = target_family_id
    AND (exclude_user_id IS NULL OR sub.user_id != exclude_user_id);
$$;
