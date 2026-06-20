-- 018_self_registration.sql — self-service onboarding (v3).
-- Flips membership from admin-invite-only to self-registration WITH admin approval:
--   * New sign-ups (email/password or Google) land as PENDING (is_active = false)
--     and only become members once an admin approves them.
--   * The profile now carries the richer KYC fields collected at registration.
--   * Members may edit their OWN details via update_own_profile(), which can never
--     touch role/is_active (those stay admin-controlled). No broad self-UPDATE policy
--     is added, so a member still cannot self-activate or self-promote.
-- Apply after 017.

-- ---------------------------------------------------------------------------
-- 1. Richer profile fields. All nullable so Google users (who arrive with only a
--    name + email) can complete them afterwards via /complete-profile.
-- ---------------------------------------------------------------------------
ALTER TABLE profiles
  ADD COLUMN IF NOT EXISTS email             text,
  ADD COLUMN IF NOT EXISTS secondary_phone   text,
  ADD COLUMN IF NOT EXISTS residence         text,
  ADD COLUMN IF NOT EXISTS national_id       text,
  ADD COLUMN IF NOT EXISTS next_of_kin_name  text,
  ADD COLUMN IF NOT EXISTS next_of_kin_phone text;

-- ---------------------------------------------------------------------------
-- 2. Pending-by-default trigger. Self-registered users start inactive; the
--    admin-create-member Edge Function flips is_active=true for admin-added members.
--    full_name is NOT NULL, so fall back to the email local-part for OAuth users
--    whose provider somehow omits a name. NULLIF('') keeps blank metadata as NULL
--    (so the UNIQUE phone constraint allows many blank pending sign-ups).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.profiles (
    id, full_name, phone_number, secondary_phone, email,
    residence, national_id, next_of_kin_name, next_of_kin_phone, is_active
  )
  VALUES (
    NEW.id,
    COALESCE(NULLIF(NEW.raw_user_meta_data->>'full_name', ''), split_part(NEW.email, '@', 1)),
    NULLIF(NEW.raw_user_meta_data->>'phone_number', ''),
    NULLIF(NEW.raw_user_meta_data->>'secondary_phone', ''),
    NEW.email,
    NULLIF(NEW.raw_user_meta_data->>'residence', ''),
    NULLIF(NEW.raw_user_meta_data->>'national_id', ''),
    NULLIF(NEW.raw_user_meta_data->>'next_of_kin_name', ''),
    NULLIF(NEW.raw_user_meta_data->>'next_of_kin_phone', ''),
    false
  );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- ---------------------------------------------------------------------------
-- 3. update_own_profile — a member edits ONLY their own editable fields. Never
--    touches id / role / is_active / email, so it can't be used to self-activate
--    or self-promote. Used by /complete-profile and the Profile page.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION update_own_profile(
  p_full_name        text,
  p_phone_number     text,
  p_secondary_phone  text,
  p_residence        text,
  p_national_id      text,
  p_next_of_kin_name text,
  p_next_of_kin_phone text
)
RETURNS void AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF COALESCE(NULLIF(trim(p_full_name), ''), '') = '' THEN
    RAISE EXCEPTION 'Full name is required';
  END IF;
  UPDATE profiles SET
    full_name         = trim(p_full_name),
    phone_number      = NULLIF(trim(p_phone_number), ''),
    secondary_phone   = NULLIF(trim(p_secondary_phone), ''),
    residence         = NULLIF(trim(p_residence), ''),
    national_id       = NULLIF(trim(p_national_id), ''),
    next_of_kin_name  = NULLIF(trim(p_next_of_kin_name), ''),
    next_of_kin_phone = NULLIF(trim(p_next_of_kin_phone), '')
  WHERE id = auth.uid();
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- ---------------------------------------------------------------------------
-- 4. approve_member — admin activates a pending sign-up. Single-admin (like
--    admin-create-member) so it works right after a reset when only one admin
--    exists. Audited.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION approve_member(p_member_id uuid)
RETURNS void AS $$
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  UPDATE profiles SET is_active = true
   WHERE id = p_member_id AND is_active = false;
  IF NOT FOUND THEN RAISE EXCEPTION 'Member not found or already active'; END IF;
  INSERT INTO audit_log (actor_id, action, target_type, target_id)
  VALUES (auth.uid(), 'approve_member', 'profile', p_member_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- ---------------------------------------------------------------------------
-- 5. reject_pending_member — admin declines a pending sign-up, removing the auth
--    user (cascades to the profile). Only valid for inactive, non-admin members;
--    active members must go through the 2-of-N member-deletion flow instead.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reject_pending_member(p_member_id uuid)
RETURNS void AS $$
DECLARE
  v_role   text;
  v_active boolean;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'Not authorized'; END IF;
  SELECT role, is_active INTO v_role, v_active FROM profiles WHERE id = p_member_id;
  IF NOT FOUND      THEN RAISE EXCEPTION 'Member not found'; END IF;
  IF v_active       THEN RAISE EXCEPTION 'Member is already active; use member deletion instead'; END IF;
  IF v_role = 'admin' THEN RAISE EXCEPTION 'Cannot reject an admin'; END IF;
  INSERT INTO audit_log (actor_id, action, target_type, target_id)
  VALUES (auth.uid(), 'reject_pending_member', 'profile', p_member_id);
  DELETE FROM auth.users WHERE id = p_member_id;  -- cascades to profiles
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

GRANT EXECUTE ON FUNCTION update_own_profile(text, text, text, text, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION approve_member(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION reject_pending_member(uuid) TO authenticated;
