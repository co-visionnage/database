-- =========================================================================
-- 034: series_id события просмотра мог принадлежать другой семье
--
-- Перенос миграции 028 из notrecinema-app (PR #66 монолита), см. комментарий
-- в 0032 о том, почему эти исправления оказались не в схеме.
--
-- family_watch_events_insert_member проверяла только, что family_id --
-- семья, в которой состоит автор, и что created_by совпадает с вызывающим.
-- Необязательный series_id она не проверяла вовсе: FK требует лишь, чтобы
-- строка существовала где-нибудь, а не в той же семье. То же самое уже
-- явно охраняют createWatchPollAction и family_watch_poll_options.
--
-- Влияние ограничено (успех или отказ вставки работает как оракул
-- существования UUID сериалов в чужих семьях, плюс повисшая связь
-- событие->сериал; сами данные сериала не утекают, чтение JOIN-а по-прежнему
-- фильтруется RLS), но исправление дешёвое и возвращает таблице ту же
-- дисциплину изоляции по семьям, что и у остальной схемы.
-- =========================================================================

DROP POLICY IF EXISTS family_watch_events_insert_member ON public.family_watch_events;
CREATE POLICY family_watch_events_insert_member
  ON public.family_watch_events
  FOR INSERT
  WITH CHECK (
    public.is_family_member(family_id)
    AND created_by = public.current_user_id()
    AND (
      series_id IS NULL
      OR EXISTS (
        SELECT 1 FROM public.family_series series
        WHERE series.id = family_watch_events.series_id
          AND series.family_id = family_watch_events.family_id
      )
    )
  );
