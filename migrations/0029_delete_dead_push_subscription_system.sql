-- =========================================================================
-- 029: let the worker delete a push subscription that turned out dead
--
-- webpush.Sender.Send maps a 404/410 response from the push service to
-- "this subscription no longer exists" (browser unsubscribed, cleared
-- data). Until now the worker only logged that and left the row in
-- push_subscriptions -- push_subscriptions_owner_only (migration 0007)
-- forbids deleting a row that isn't the caller's own, and the worker has
-- no per-user app.current_user_id to be that caller. This SECURITY
-- DEFINER function is scoped by endpoint (globally unique, see the
-- UNIQUE(endpoint) constraint from 0007) rather than by user, which is
-- all the worker knows at the point a send fails.
-- =========================================================================

CREATE OR REPLACE FUNCTION public.delete_push_subscription_system(
  target_endpoint text
)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
AS $$
  DELETE FROM public.push_subscriptions WHERE endpoint = target_endpoint;
$$;
