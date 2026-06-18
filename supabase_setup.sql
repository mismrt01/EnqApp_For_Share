-- ============================================================
-- EnqBoss – Full Supabase Setup (run this ONE file)
-- ============================================================
-- Paste this entire script into the Supabase SQL Editor and Run.
-- Idempotent & safe to re-run (IF NOT EXISTS / DROP ... IF EXISTS).
--
-- Access model: a logged-in user may read/write data only if their email
-- is on the allow-list OR matches the tenant's org domain (set at setup).
-- Enforced by RLS via is_app_member().
--
-- >>> BEFORE RUNNING: replace __SET_ADMIN_EMAIL__ (line in section 1) with
--     the first admin's email. <<<
-- ============================================================

-- ------------------------------------------------------------
-- 0. SHARED HELPERS
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 1. CONTROL TABLES (tenant config, allow-list, registrations)
-- ============================================================
CREATE TABLE IF NOT EXISTS tenant_config (
    id          TEXT PRIMARY KEY DEFAULT 'tenant',
    company     TEXT,
    org_domain  TEXT,                       -- e.g. 'acme.com' (no @)
    labels      JSONB DEFAULT '{}'::jsonb,  -- custom UI labels (rename map)
    setup_done  BOOLEAN DEFAULT false,
    setup_email TEXT,
    install_id  TEXT,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);
INSERT INTO tenant_config (id) VALUES ('tenant') ON CONFLICT (id) DO NOTHING;
-- Backfill for installs created before 'labels' existed:
ALTER TABLE tenant_config ADD COLUMN IF NOT EXISTS labels JSONB DEFAULT '{}'::jsonb;

CREATE TABLE IF NOT EXISTS allowed_users (
    email      TEXT PRIMARY KEY,
    role       TEXT NOT NULL DEFAULT 'member',  -- 'admin' | 'member'
    added_by   TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS install_registrations (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    install_id  TEXT,
    company     TEXT,
    org_domain  TEXT,
    setup_email TEXT,
    sent        BOOLEAN DEFAULT false,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

-- Access helper: true if JWT email is allow-listed OR matches org domain.
CREATE OR REPLACE FUNCTION is_app_member()
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT
      EXISTS (
        SELECT 1 FROM allowed_users
        WHERE lower(email) = lower(auth.jwt() ->> 'email')
      )
      OR EXISTS (
        SELECT 1 FROM tenant_config
        WHERE org_domain IS NOT NULL AND org_domain <> ''
          AND lower(auth.jwt() ->> 'email') LIKE '%@' || lower(org_domain)
      );
$$;

-- >>> REPLACE the email below before running. <<<
INSERT INTO allowed_users (email, role, added_by)
VALUES ('__SET_ADMIN_EMAIL__', 'admin', 'setup')
ON CONFLICT (email) DO UPDATE SET role = 'admin';

-- ============================================================
-- 2. CORE DATA TABLES
-- ============================================================
CREATE TABLE IF NOT EXISTS customers (
    id         TEXT PRIMARY KEY,
    code       TEXT UNIQUE NOT NULL,
    name       TEXT NOT NULL,
    seg        TEXT,
    gstin      TEXT,
    inco       TEXT,
    curr       TEXT DEFAULT 'INR',
    pay        TEXT DEFAULT '30 days',
    sites      JSONB DEFAULT '[]'::jsonb,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS enquiries (
    id              TEXT PRIMARY KEY,
    recv            TIMESTAMPTZ NOT NULL,
    src             TEXT NOT NULL,
    cust            TEXT NOT NULL,
    site_id         TEXT,
    contact_id      TEXT,
    contact         TEXT,
    email           TEXT,
    urg             TEXT DEFAULT 'Normal',
    status          TEXT DEFAULT 'New',
    assigned        TEXT,
    notes           TEXT,
    items           JSONB DEFAULT '[]'::jsonb,
    attachments     JSONB DEFAULT '[]'::jsonb,
    age_h           INTEGER DEFAULT 0,
    q_ref           TEXT,
    cust_enq_doc_no TEXT,
    gmail_message_id TEXT,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS quotes (
    id                TEXT PRIMARY KEY,
    enq_ref           TEXT REFERENCES enquiries(id),
    cust              TEXT NOT NULL,
    date              DATE NOT NULL,
    validity          DATE,
    status            TEXT DEFAULT 'Sent',
    inco              TEXT,
    curr              TEXT,
    pay               TEXT,
    items             JSONB DEFAULT '[]'::jsonb,
    attachments       JSONB DEFAULT '[]'::jsonb,
    authorized_person JSONB,
    terms             TEXT,
    created_at        TIMESTAMPTZ DEFAULT NOW(),
    updated_at        TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS orders (
    id                TEXT PRIMARY KEY,
    quote_ref         TEXT REFERENCES quotes(id),
    enq_ref           TEXT REFERENCES enquiries(id),
    cust              TEXT NOT NULL,
    po_no             TEXT NOT NULL,
    po_date           DATE NOT NULL,
    dlv_date          DATE,
    status            TEXT DEFAULT 'Processing',
    value             NUMERIC DEFAULT 0,
    inco              TEXT,
    items             JSONB DEFAULT '[]'::jsonb,
    attachments       JSONB DEFAULT '[]'::jsonb,
    authorized_person JSONB,
    terms             TEXT,
    po_filename       TEXT,
    created_at        TIMESTAMPTZ DEFAULT NOW(),
    updated_at        TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS followups (
    id         TEXT PRIMARY KEY,
    quote_id   TEXT UNIQUE NOT NULL REFERENCES quotes(id) ON DELETE CASCADE,
    owner      TEXT,
    next_date  DATE,
    next_time  TEXT,
    status     TEXT DEFAULT 'open',
    logs       JSONB NOT NULL DEFAULT '[]'::jsonb,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_followups_quote_id  ON followups(quote_id);
CREATE INDEX IF NOT EXISTS idx_followups_next_date ON followups(next_date);
DROP TRIGGER IF EXISTS update_followups_modtime ON followups;
CREATE TRIGGER update_followups_modtime
BEFORE UPDATE ON followups
FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TABLE IF NOT EXISTS app_settings (
    id         TEXT PRIMARY KEY DEFAULT 'config',
    header_url TEXT,
    sig_name   TEXT DEFAULT 'Akash Gupta',
    sig_des    TEXT DEFAULT 'Rubber Technologist',
    sig_phone  TEXT DEFAULT '+91-817171 6630',
    sig_url    TEXT,
    bank_name  TEXT DEFAULT 'ICICI BANK LTD.',
    bank_acc   TEXT DEFAULT '0000000000',
    bank_ifsc  TEXT DEFAULT 'ICIC0000000',
    bank_swift TEXT,
    gmail_enabled   BOOLEAN DEFAULT false,
    gmail_labels    JSONB DEFAULT '[]'::jsonb,
    gmail_sync_freq INTEGER DEFAULT 0,
    gmail_last_sync TIMESTAMPTZ,
    updated_at TIMESTAMPTZ DEFAULT NOW()
);
INSERT INTO app_settings (id) VALUES ('config') ON CONFLICT (id) DO NOTHING;

CREATE TABLE IF NOT EXISTS authorized_signatories (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    designation TEXT NOT NULL,
    phone       TEXT,
    is_default  BOOLEAN DEFAULT false,
    created_at  TIMESTAMPTZ DEFAULT NOW(),
    updated_at  TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- 3. ROW LEVEL SECURITY
-- ============================================================
ALTER TABLE customers              ENABLE ROW LEVEL SECURITY;
ALTER TABLE enquiries              ENABLE ROW LEVEL SECURITY;
ALTER TABLE quotes                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE orders                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE followups              ENABLE ROW LEVEL SECURITY;
ALTER TABLE app_settings           ENABLE ROW LEVEL SECURITY;
ALTER TABLE authorized_signatories ENABLE ROW LEVEL SECURITY;
ALTER TABLE tenant_config          ENABLE ROW LEVEL SECURITY;
ALTER TABLE allowed_users          ENABLE ROW LEVEL SECURITY;
ALTER TABLE install_registrations  ENABLE ROW LEVEL SECURITY;

-- Member access on all data tables.
DO $$
DECLARE t TEXT;
        tables TEXT[] := ARRAY[
          'customers','enquiries','quotes','orders',
          'followups','app_settings','authorized_signatories'];
BEGIN
    FOREACH t IN ARRAY tables LOOP
        EXECUTE format('DROP POLICY IF EXISTS "Allow company access" ON public.%I', t);
        EXECUTE format('DROP POLICY IF EXISTS "Allow member access"  ON public.%I', t);
        EXECUTE format('DROP POLICY IF EXISTS "Enable all for authenticated users" ON public.%I', t);
        EXECUTE format($f$
            CREATE POLICY "Allow member access" ON public.%I
            FOR ALL TO authenticated
            USING (is_app_member()) WITH CHECK (is_app_member())
        $f$, t);
    END LOOP;
END $$;

-- tenant_config: any authenticated user may READ; admins (or during first
-- setup) may write.
DROP POLICY IF EXISTS "tenant read"  ON tenant_config;
DROP POLICY IF EXISTS "tenant write" ON tenant_config;
CREATE POLICY "tenant read"  ON tenant_config FOR SELECT TO authenticated USING (true);
CREATE POLICY "tenant write" ON tenant_config FOR ALL TO authenticated
    USING (EXISTS (SELECT 1 FROM allowed_users WHERE lower(email)=lower(auth.jwt()->>'email') AND role='admin')
           OR NOT (SELECT setup_done FROM tenant_config WHERE id='tenant'))
    WITH CHECK (EXISTS (SELECT 1 FROM allowed_users WHERE lower(email)=lower(auth.jwt()->>'email') AND role='admin')
           OR NOT (SELECT setup_done FROM tenant_config WHERE id='tenant'));

-- allowed_users: members read; admins manage.
DROP POLICY IF EXISTS "allow read"  ON allowed_users;
DROP POLICY IF EXISTS "allow admin" ON allowed_users;
CREATE POLICY "allow read"  ON allowed_users FOR SELECT TO authenticated USING (is_app_member());
CREATE POLICY "allow admin" ON allowed_users FOR ALL TO authenticated
    USING (EXISTS (SELECT 1 FROM allowed_users a WHERE lower(a.email)=lower(auth.jwt()->>'email') AND a.role='admin'))
    WITH CHECK (EXISTS (SELECT 1 FROM allowed_users a WHERE lower(a.email)=lower(auth.jwt()->>'email') AND a.role='admin'));

-- install_registrations: any authed user may INSERT (one-time at setup);
-- admins may read.
DROP POLICY IF EXISTS "reg insert" ON install_registrations;
DROP POLICY IF EXISTS "reg read"   ON install_registrations;
CREATE POLICY "reg insert" ON install_registrations FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY "reg read"   ON install_registrations FOR SELECT TO authenticated
    USING (EXISTS (SELECT 1 FROM allowed_users WHERE lower(email)=lower(auth.jwt()->>'email') AND role='admin'));

-- ============================================================
-- 4. STORAGE BUCKET POLICIES
-- Create buckets first in Storage > Buckets:
--   'Docs'          (Public = false)
--   'public-assets' (Public = true)   -- optional
-- ============================================================
DROP POLICY IF EXISTS "Allow authenticated uploads"   ON storage.objects;
DROP POLICY IF EXISTS "Allow authenticated updates"   ON storage.objects;
DROP POLICY IF EXISTS "Allow authenticated downloads" ON storage.objects;
DROP POLICY IF EXISTS "Allow authenticated deletes"   ON storage.objects;
CREATE POLICY "Allow authenticated uploads"
  ON storage.objects FOR INSERT TO authenticated WITH CHECK (bucket_id = 'Docs');
CREATE POLICY "Allow authenticated updates"
  ON storage.objects FOR UPDATE TO authenticated USING (bucket_id = 'Docs');
CREATE POLICY "Allow authenticated downloads"
  ON storage.objects FOR SELECT TO authenticated USING (bucket_id = 'Docs');
CREATE POLICY "Allow authenticated deletes"
  ON storage.objects FOR DELETE TO authenticated USING (bucket_id = 'Docs');

DROP POLICY IF EXISTS "Allow authenticated uploads to public assets" ON storage.objects;
DROP POLICY IF EXISTS "Allow public select from public assets"       ON storage.objects;
DROP POLICY IF EXISTS "Allow authenticated updates to public assets" ON storage.objects;
CREATE POLICY "Allow authenticated uploads to public assets"
  ON storage.objects FOR INSERT TO authenticated WITH CHECK (bucket_id = 'public-assets');
CREATE POLICY "Allow public select from public assets"
  ON storage.objects FOR SELECT TO public USING (bucket_id = 'public-assets');
CREATE POLICY "Allow authenticated updates to public assets"
  ON storage.objects FOR UPDATE TO authenticated USING (bucket_id = 'public-assets');

-- ============================================================
-- DONE.
-- ============================================================
