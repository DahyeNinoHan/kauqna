
-- ============================================================
-- 1. PROFILES
-- ============================================================
CREATE TABLE public.profiles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL UNIQUE REFERENCES auth.users(id) ON DELETE CASCADE,
  display_name TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

GRANT SELECT, INSERT, UPDATE ON public.profiles TO authenticated;
GRANT ALL ON public.profiles TO service_role;

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own profile" ON public.profiles FOR SELECT TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "Users can insert own profile" ON public.profiles FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users can update own profile" ON public.profiles FOR UPDATE TO authenticated USING (auth.uid() = user_id);

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO public.profiles (user_id, display_name)
  VALUES (NEW.id, COALESCE(NEW.raw_user_meta_data->>'display_name', NEW.raw_user_meta_data->>'full_name', split_part(NEW.email, '@', 1)))
  ON CONFLICT (user_id) DO NOTHING;
  RETURN NEW;
END;
$$;

CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = public AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END;
$$;

CREATE TRIGGER update_profiles_updated_at BEFORE UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- ============================================================
-- 2. EVENTS
-- ============================================================
CREATE TABLE public.events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  code TEXT NOT NULL UNIQUE,
  title TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','active','closed')),
  allow_anonymous BOOLEAN NOT NULL DEFAULT true,
  require_moderation BOOLEAN NOT NULL DEFAULT false,
  paid BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  activated_at TIMESTAMPTZ,
  closed_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_events_owner ON public.events(owner_id);
CREATE INDEX idx_events_code ON public.events(code);

GRANT SELECT ON public.events TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.events TO authenticated;
GRANT ALL ON public.events TO service_role;

ALTER TABLE public.events ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone can view active events" ON public.events FOR SELECT TO anon, authenticated USING (status = 'active');
CREATE POLICY "Owners can view own events" ON public.events FOR SELECT TO authenticated USING (auth.uid() = owner_id);
CREATE POLICY "Owners can insert own events" ON public.events FOR INSERT TO authenticated WITH CHECK (auth.uid() = owner_id);
CREATE POLICY "Owners can update own events" ON public.events FOR UPDATE TO authenticated USING (auth.uid() = owner_id);
CREATE POLICY "Owners can delete own events" ON public.events FOR DELETE TO authenticated USING (auth.uid() = owner_id);

CREATE TRIGGER update_events_updated_at BEFORE UPDATE ON public.events FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE OR REPLACE FUNCTION public.is_event_active(_event_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.events WHERE id = _event_id AND status = 'active');
$$;

CREATE OR REPLACE FUNCTION public.is_event_owner(_event_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.events WHERE id = _event_id AND owner_id = auth.uid());
$$;

-- ============================================================
-- 3. QUESTIONS — extend
-- ============================================================
DELETE FROM public.questions;

DROP POLICY IF EXISTS "Anyone can view questions" ON public.questions;
DROP POLICY IF EXISTS "Anyone can insert questions" ON public.questions;
DROP POLICY IF EXISTS "Anyone can upvote questions" ON public.questions;
DROP POLICY IF EXISTS "Anyone can delete questions" ON public.questions;

ALTER TABLE public.questions
  ADD COLUMN event_id UUID NOT NULL REFERENCES public.events(id) ON DELETE CASCADE,
  ADD COLUMN is_hidden BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN is_pinned BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN is_flagged BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN moderation_status TEXT NOT NULL DEFAULT 'approved' CHECK (moderation_status IN ('pending','approved','rejected')),
  ADD COLUMN author_nickname TEXT;

CREATE INDEX idx_questions_event ON public.questions(event_id);

CREATE POLICY "Anyone can view approved questions of active events" ON public.questions FOR SELECT TO anon, authenticated
  USING (public.is_event_active(event_id) AND is_hidden = false AND moderation_status = 'approved');

CREATE POLICY "Owners can view all questions in own events" ON public.questions FOR SELECT TO authenticated
  USING (public.is_event_owner(event_id));

CREATE POLICY "Anyone can insert questions into active events" ON public.questions FOR INSERT TO anon, authenticated
  WITH CHECK (public.is_event_active(event_id) AND moderation_status IN ('pending','approved') AND is_hidden = false AND is_pinned = false AND is_flagged = false);

CREATE POLICY "Anyone can upvote questions in active events" ON public.questions FOR UPDATE TO anon, authenticated
  USING (public.is_event_active(event_id) AND is_hidden = false AND moderation_status = 'approved')
  WITH CHECK (public.is_event_active(event_id));

CREATE POLICY "Owners can update questions in own events" ON public.questions FOR UPDATE TO authenticated
  USING (public.is_event_owner(event_id)) WITH CHECK (public.is_event_owner(event_id));

CREATE POLICY "Owners can delete questions in own events" ON public.questions FOR DELETE TO authenticated
  USING (public.is_event_owner(event_id));

-- Add events to realtime (questions already in publication)
DO $$ BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.events;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ============================================================
-- 4. PAYMENTS
-- ============================================================
CREATE TABLE public.payments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  event_id UUID REFERENCES public.events(id) ON DELETE SET NULL,
  stripe_session_id TEXT UNIQUE,
  stripe_payment_intent_id TEXT,
  amount_cents INTEGER NOT NULL,
  currency TEXT NOT NULL DEFAULT 'usd',
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','paid','failed','refunded')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_payments_user ON public.payments(user_id);
CREATE INDEX idx_payments_event ON public.payments(event_id);

GRANT SELECT ON public.payments TO authenticated;
GRANT ALL ON public.payments TO service_role;

ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own payments" ON public.payments FOR SELECT TO authenticated USING (auth.uid() = user_id);

CREATE TRIGGER update_payments_updated_at BEFORE UPDATE ON public.payments FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- ============================================================
-- 5. FREE EVENT USAGE
-- ============================================================
CREATE TABLE public.free_event_usage (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  year_month TEXT NOT NULL,
  used_count INTEGER NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, year_month)
);

CREATE INDEX idx_free_event_usage_user ON public.free_event_usage(user_id);

GRANT SELECT ON public.free_event_usage TO authenticated;
GRANT ALL ON public.free_event_usage TO service_role;

ALTER TABLE public.free_event_usage ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own free usage" ON public.free_event_usage FOR SELECT TO authenticated USING (auth.uid() = user_id);

CREATE TRIGGER update_free_event_usage_updated_at BEFORE UPDATE ON public.free_event_usage FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
