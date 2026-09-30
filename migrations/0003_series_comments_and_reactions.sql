-- =========================================================================
-- 003: series comments + reactions
-- =========================================================================

CREATE TABLE IF NOT EXISTS public.family_series_comments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  series_id uuid NOT NULL REFERENCES public.family_series(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  body text NOT NULL CHECK (
    char_length(btrim(body)) > 0 AND char_length(body) <= 2000
  ),
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS family_series_comments_series_id_index
  ON public.family_series_comments (series_id);

DROP TRIGGER IF EXISTS family_series_comments_touch_updated_at ON public.family_series_comments;
CREATE TRIGGER family_series_comments_touch_updated_at
  BEFORE UPDATE ON public.family_series_comments
  FOR EACH ROW
  EXECUTE FUNCTION public.touch_updated_at();

CREATE TABLE IF NOT EXISTS public.family_series_reactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  series_id uuid NOT NULL REFERENCES public.family_series(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  emoji varchar(8) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  UNIQUE (series_id, user_id, emoji)
);

CREATE INDEX IF NOT EXISTS family_series_reactions_series_id_index
  ON public.family_series_reactions (series_id);

ALTER TABLE public.family_series_comments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.family_series_comments FORCE ROW LEVEL SECURITY;
ALTER TABLE public.family_series_reactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.family_series_reactions FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS family_series_comments_select_member ON public.family_series_comments;
CREATE POLICY family_series_comments_select_member
  ON public.family_series_comments
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.family_series series
      WHERE series.id = family_series_comments.series_id
        AND public.is_family_member(series.family_id)
    )
  );

DROP POLICY IF EXISTS family_series_comments_insert_member ON public.family_series_comments;
CREATE POLICY family_series_comments_insert_member
  ON public.family_series_comments
  FOR INSERT
  WITH CHECK (
    user_id = public.current_user_id()
    AND EXISTS (
      SELECT 1 FROM public.family_series series
      WHERE series.id = family_series_comments.series_id
        AND public.is_family_member(series.family_id)
    )
  );

DROP POLICY IF EXISTS family_series_comments_update_author ON public.family_series_comments;
CREATE POLICY family_series_comments_update_author
  ON public.family_series_comments
  FOR UPDATE
  USING (user_id = public.current_user_id())
  WITH CHECK (user_id = public.current_user_id());

DROP POLICY IF EXISTS family_series_comments_delete_author_or_owner ON public.family_series_comments;
CREATE POLICY family_series_comments_delete_author_or_owner
  ON public.family_series_comments
  FOR DELETE
  USING (
    user_id = public.current_user_id()
    OR EXISTS (
      SELECT 1 FROM public.family_series series
      WHERE series.id = family_series_comments.series_id
        AND public.is_family_owner(series.family_id)
    )
  );

DROP POLICY IF EXISTS family_series_reactions_select_member ON public.family_series_reactions;
CREATE POLICY family_series_reactions_select_member
  ON public.family_series_reactions
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.family_series series
      WHERE series.id = family_series_reactions.series_id
        AND public.is_family_member(series.family_id)
    )
  );

DROP POLICY IF EXISTS family_series_reactions_insert_member ON public.family_series_reactions;
CREATE POLICY family_series_reactions_insert_member
  ON public.family_series_reactions
  FOR INSERT
  WITH CHECK (
    user_id = public.current_user_id()
    AND EXISTS (
      SELECT 1 FROM public.family_series series
      WHERE series.id = family_series_reactions.series_id
        AND public.is_family_member(series.family_id)
    )
  );

DROP POLICY IF EXISTS family_series_reactions_delete_own ON public.family_series_reactions;
CREATE POLICY family_series_reactions_delete_own
  ON public.family_series_reactions
  FOR DELETE
  USING (user_id = public.current_user_id());
