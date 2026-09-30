-- =========================================================================
-- 007: web push subscriptions
-- =========================================================================

CREATE TABLE IF NOT EXISTS public.push_subscriptions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  endpoint text NOT NULL,
  p256dh text NOT NULL,
  auth text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  UNIQUE (endpoint)
);

CREATE INDEX IF NOT EXISTS push_subscriptions_user_id_index
  ON public.push_subscriptions (user_id);

ALTER TABLE public.push_subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.push_subscriptions FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS push_subscriptions_owner_only ON public.push_subscriptions;
CREATE POLICY push_subscriptions_owner_only
  ON public.push_subscriptions
  FOR ALL
  USING (user_id = public.current_user_id())
  WITH CHECK (user_id = public.current_user_id());

-- SECURITY DEFINER: notifying a family requires reading the OTHER members'
-- subscriptions, which push_subscriptions_owner_only intentionally forbids
-- for a normal RLS-scoped connection. Access is still gated by
-- is_family_member(), which checks the CALLER (current_user_id()) is
-- themself a member of target_family_id before returning anything.
CREATE OR REPLACE FUNCTION public.get_family_push_subscriptions(
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
    AND sub.user_id != exclude_user_id
    AND public.is_family_member(target_family_id);
$$;
