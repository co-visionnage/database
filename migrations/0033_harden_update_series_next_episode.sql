-- =========================================================================
-- 033: update_series_next_episode не должна доверять только аргументу
--
-- Перенос миграции 027 из notrecinema-app (PR #64 монолита), см. комментарий
-- в 0032 о том, почему эти исправления оказались не в схеме.
--
-- update_series_next_episode -- SECURITY DEFINER без проверки, что
-- вызывающая сессия состоит в семье этого сериала. Сегодня до неё можно
-- добраться только через checkNextEpisodeAction (и её Go-аналог
-- internal/calendar), которые сначала читают сериал под RLS и падают, если
-- он невидим, -- так что эксплуатировать это сейчас нельзя. Но сама запись
-- такой защиты не имеет, как и delete_own_profile до 0025: будущий
-- рефакторинг, пропускающий или переставляющий эту проверку, превратил бы
-- функцию в межтенантную запись, которую уже ничто не остановит.
--
-- Ограничение `AND public.is_family_member(family_id)` ничего не стоит для
-- законного случая и делает функцию безопасной по построению.
-- =========================================================================

CREATE OR REPLACE FUNCTION public.update_series_next_episode(
  target_series_id uuid,
  new_air_date date,
  new_label text
)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
AS $$
  UPDATE public.family_series
  SET next_episode_air_date = new_air_date,
      next_episode_label = new_label
  WHERE id = target_series_id
    AND public.is_family_member(family_id);
$$;
