-- 004_storage_bucket.sql — private proof bucket + storage RLS (build plan §7).

-- Bucket: private, images only, ≤ 5 MB. Supabase enforces mime/size server-side.
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('payment-proofs', 'payment-proofs', false, 5242880,
        ARRAY['image/jpeg', 'image/png', 'image/webp'])
ON CONFLICT (id) DO UPDATE
  SET file_size_limit    = EXCLUDED.file_size_limit,
      allowed_mime_types = EXCLUDED.allowed_mime_types;

-- Path structure puts member_id as the 2nd segment for member uploads, e.g.
--   savings/{member_id}/{submission_id}.jpg
--   fees/{member_id}/{period}/{submission_id}.jpg
--   loan-repayments/{member_id}/{loan_id}/{installment_number}/{submission_id}.jpg
-- Admin disbursement proofs live under loan-disbursements/{loan_id}/...

-- Members upload only under their own id (2nd folder segment).
CREATE POLICY "member upload own proofs"
  ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'payment-proofs'
              AND (storage.foldername(name))[2] = auth.uid()::text);

-- Members read their own files; admins read ALL files (so the admin client can mint
-- signed URLs directly — no service-role key in the browser).
CREATE POLICY "read own or admin"
  ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'payment-proofs'
         AND ((storage.foldername(name))[2] = auth.uid()::text OR is_admin()));

-- Admins upload disbursement proofs.
CREATE POLICY "admin upload disbursements"
  ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'payment-proofs' AND is_admin());
