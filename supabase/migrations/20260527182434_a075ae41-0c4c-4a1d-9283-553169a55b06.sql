
CREATE TABLE public.questions (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  text TEXT NOT NULL CHECK (char_length(text) > 0 AND char_length(text) <= 500),
  upvotes INTEGER NOT NULL DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

GRANT SELECT, INSERT, UPDATE ON public.questions TO anon, authenticated;
GRANT ALL ON public.questions TO service_role;

ALTER TABLE public.questions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone can view questions" ON public.questions FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY "Anyone can insert questions" ON public.questions FOR INSERT TO anon, authenticated WITH CHECK (true);
CREATE POLICY "Anyone can upvote questions" ON public.questions FOR UPDATE TO anon, authenticated USING (true) WITH CHECK (true);

-- Atomic upvote function
CREATE OR REPLACE FUNCTION public.increment_upvote(question_id UUID)
RETURNS INTEGER
LANGUAGE SQL
SECURITY DEFINER
SET search_path = public
AS $$
  UPDATE public.questions
  SET upvotes = upvotes + 1
  WHERE id = question_id
  RETURNING upvotes;
$$;

GRANT EXECUTE ON FUNCTION public.increment_upvote(UUID) TO anon, authenticated;

ALTER PUBLICATION supabase_realtime ADD TABLE public.questions;
ALTER TABLE public.questions REPLICA IDENTITY FULL;
