-- =========================================================================
-- 032: у family_members не было политики UPDATE -- смена роли была no-op
--
-- Перенос миграции 026 из notrecinema-app (PR #62 монолита): эти три
-- исправления (032-034 здесь) остались только в папке database/ монолита и
-- в схему не попали, поэтому любая новая база, собранная из этого
-- репозитория, их не получала. Миграции идемпотентны (DROP POLICY IF EXISTS /
-- CREATE OR REPLACE): базы, где монолитные версии уже применены, не
-- пострадают.
--
-- family_members имеет ENABLE + FORCE ROW LEVEL SECURITY (0001) с политиками
-- SELECT, INSERT и DELETE, но ни одна миграция не добавляла UPDATE.
-- app_user не обходит RLS, поэтому прямой
-- `UPDATE public.family_members SET role = ...` затрагивал ноль строк при
-- любом вызывающем -- и не было ошибки: UPDATE 0 rows -- не ошибка.
--
-- Политика повторяет то, что приложение и так проверяет перед UPDATE:
-- менять роль может только владелец семьи, а роль самого владельца так не
-- меняется (владение передаёт только transfer_family_ownership).
--
-- set_family_member_role (0030) остаётся рабочим путём для Go-сервиса: он
-- SECURITY DEFINER и сам проверяет владельца. Эта политика закрывает прямой
-- UPDATE для остальных вызывающих (в том числе для notrecinema-app).
-- =========================================================================

DROP POLICY IF EXISTS family_members_update_owner ON public.family_members;
CREATE POLICY family_members_update_owner
  ON public.family_members
  FOR UPDATE
  USING (public.is_family_owner(family_id) AND role != 'owner')
  WITH CHECK (public.is_family_owner(family_id) AND role != 'owner');
