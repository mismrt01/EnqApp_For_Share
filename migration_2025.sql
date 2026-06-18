-- ============================================================
-- MRT ERP – Migration: May 2025
-- Run this entire script in your Supabase SQL Editor
-- ============================================================

-- 1. RLS on authorized_signatories now uses is_app_member()
--    (allow-list OR tenant org domain). See supabase_schema.sql for the helper.
DROP POLICY IF EXISTS "Allow company access" ON public.authorized_signatories;
DROP POLICY IF EXISTS "Allow member access"  ON public.authorized_signatories;
CREATE POLICY "Allow member access"
ON public.authorized_signatories
FOR ALL TO authenticated
USING (is_app_member()) WITH CHECK (is_app_member());

-- 2. Add missing columns to quotes table
ALTER TABLE public.quotes
  ADD COLUMN IF NOT EXISTS authorized_person JSONB,
  ADD COLUMN IF NOT EXISTS terms             TEXT;

-- 3. Add missing columns to orders table
ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS authorized_person JSONB,
  ADD COLUMN IF NOT EXISTS terms             TEXT,
  ADD COLUMN IF NOT EXISTS inco              TEXT,
  ADD COLUMN IF NOT EXISTS attachments       JSONB DEFAULT '[]'::jsonb;

-- 4. Ensure customers table has trading-terms columns
--    (Safe to run even if columns already exist)
ALTER TABLE public.customers
  ADD COLUMN IF NOT EXISTS inco TEXT,
  ADD COLUMN IF NOT EXISTS curr TEXT DEFAULT 'INR',
  ADD COLUMN IF NOT EXISTS pay  TEXT DEFAULT '30 days';

-- 5. Also add custEnqDocNo to enquiries (referenced in types.ts)
ALTER TABLE public.enquiries
  ADD COLUMN IF NOT EXISTS cust_enq_doc_no TEXT;

-- 6. Switch all core tables to the is_app_member() access model
--    (allow-list OR tenant org domain; USING + WITH CHECK).
DO $$
DECLARE t TEXT;
        tables TEXT[] := ARRAY['quotes','orders','customers','enquiries','followups'];
BEGIN
    FOREACH t IN ARRAY tables LOOP
        EXECUTE format('DROP POLICY IF EXISTS "Allow company access" ON public.%I', t);
        EXECUTE format('DROP POLICY IF EXISTS "Enable all for authenticated users" ON public.%I', t);
        EXECUTE format('DROP POLICY IF EXISTS "Allow member access" ON public.%I', t);
        EXECUTE format($f$
            CREATE POLICY "Allow member access" ON public.%I
            FOR ALL TO authenticated
            USING (is_app_member()) WITH CHECK (is_app_member())
        $f$, t);
    END LOOP;
END $$;