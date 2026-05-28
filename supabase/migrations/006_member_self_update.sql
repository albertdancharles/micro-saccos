-- 006_member_self_update.sql — let members update their own phone number from the
-- Profile page without granting blanket UPDATE on profiles. SECURITY DEFINER scopes
-- the write to auth.uid()'s row only, so the policy surface stays minimal.

CREATE OR REPLACE FUNCTION update_own_phone(p_phone text)
RETURNS void AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  UPDATE public.profiles
     SET phone_number = NULLIF(trim(p_phone), '')
   WHERE id = auth.uid();
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
