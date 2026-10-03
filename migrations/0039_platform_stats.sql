-- =========================================================================
-- 039: сводные числа платформы для метрик
--
-- notrecinema-api раз в полминуты читает эти числа и отдаёт их Prometheus
-- (platform_users, platform_families, ...): на дашборде они отвечают на
-- вопрос «растёт ли сервис и не залипло ли что-то». SECURITY DEFINER нужен,
-- потому что подсчёт идёт по таблицам под RLS без пользовательского
-- контекста; наружу выходят только числа, личных данных нет.
-- =========================================================================

CREATE OR REPLACE FUNCTION public.get_platform_stats_system()
RETURNS TABLE (
  users bigint,
  users_verified bigint,
  users_with_two_factor bigint,
  families bigint,
  series bigint,
  active_sessions bigint,
  push_subscriptions bigint,
  pending_invitations bigint
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT
    (SELECT COUNT(*) FROM public.profiles),
    (SELECT COUNT(*) FROM public.profiles WHERE email_verified_at IS NOT NULL),
    (SELECT COUNT(*) FROM public.profiles WHERE totp_enabled),
    (SELECT COUNT(*) FROM public.families),
    (SELECT COUNT(*) FROM public.family_series),
    (SELECT COUNT(*) FROM public.app_sessions WHERE expires_at > NOW()),
    (SELECT COUNT(*) FROM public.push_subscriptions),
    (SELECT COUNT(*) FROM public.family_invitations WHERE accepted_at IS NULL);
$$;
