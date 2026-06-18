-- EnqBoss - Supabase Schema (multi-tenant, consent-based setup)
-- ============================================================
-- Access model: a logged-in user may read/write data only if their
-- email matches the tenant's org domain OR is on the allow-list.
-- Enforced by RLS via the is_app_member() helper below.
-- ============================================================

-- 0a. TENANT CONFIG (org domain entered during setup)
CREATE TABLE IF NOT EXISTS tenant_config (
    id          TEXT PRIMARY KEY DEFAULT 'tenant',
    company     TEXT,
    org_domain  TEXT,           -- e.g. 'manglarubbers.com' (no @)
    setup_done  BOOLEAN DEFAULT false,
    setup_email TEXT,           -- email of the user who completed setup
    install_id  TEXT,           -- random per-deployment id
    created_at  TIMESTAMPTZ DEFAULT NOW()
);
INSERT INTO tenant_config (id) VALUES ('tenant') ON CONFLICT (id) DO NOTHING;

-- 0b. ALLOW-LIST (explicit users; admin can add more from the app)
CREATE TABLE IF NOT EXISTS allowed_users (
    email      TEXT PRIMARY KEY,
    role       TEXT NOT NULL DEFAULT 'member',  -- 'admin' | 'member'
    added_by   TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 0c. INSTALL REGISTRATIONS (non-blocking vendor record; queued send)
CREATE TABLE IF NOT EXISTS install_registrations (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    install_id  TEXT,
    company     TEXT,
    org_domain  TEXT,
    setup_email TEXT,
    sent        BOOLEAN DEFAULT false,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

-- 0d. ACCESS HELPER — true if the JWT email is allowed for this tenant.
--     SECURITY DEFINER so it can read allowed_users/tenant_config under RLS.
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

-- Seed the FIRST admin. >>> REPLACE the email below before running. <<<
INSERT INTO allowed_users (email, role, added_by)
VALUES ('__SET_ADMIN_EMAIL__', 'admin', 'setup')
ON CONFLICT (email) DO UPDATE SET role = 'admin';

-- 1. CUSTOMERS TABLE
CREATE TABLE IF NOT EXISTS customers (
    id TEXT PRIMARY KEY,
    code TEXT UNIQUE NOT NULL,
    name TEXT NOT NULL,
    seg TEXT,
    gstin TEXT,
    inco TEXT,
    curr TEXT,
    pay TEXT,
    sites JSONB DEFAULT '[]'::jsonb,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 2. ENQUIRIES TABLE
CREATE TABLE IF NOT EXISTS enquiries (
    id TEXT PRIMARY KEY,
    recv TIMESTAMPTZ NOT NULL,
    src TEXT NOT NULL,
    cust TEXT NOT NULL,
    site_id TEXT,
    contact_id TEXT,
    contact TEXT,
    email TEXT,
    urg TEXT DEFAULT 'Normal',
    status TEXT DEFAULT 'New',
    assigned TEXT,
    notes TEXT,
    items JSONB DEFAULT '[]'::jsonb,
    attachments JSONB DEFAULT '[]'::jsonb,
    age_h INTEGER DEFAULT 0,
    q_ref TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 3. QUOTES TABLE
CREATE TABLE IF NOT EXISTS quotes (
    id TEXT PRIMARY KEY,
    enq_ref TEXT REFERENCES enquiries(id),
    cust TEXT NOT NULL,
    date DATE NOT NULL,
    validity DATE,
    status TEXT DEFAULT 'Sent',
    inco TEXT,
    curr TEXT,
    pay TEXT,
    items JSONB DEFAULT '[]'::jsonb,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 4. ORDERS TABLE
CREATE TABLE IF NOT EXISTS orders (
    id TEXT PRIMARY KEY,
    quote_ref TEXT REFERENCES quotes(id),
    enq_ref TEXT REFERENCES enquiries(id),
    cust TEXT NOT NULL,
    po_no TEXT NOT NULL,
    po_date DATE NOT NULL,
    dlv_date DATE,
    status TEXT DEFAULT 'Processing',
    value NUMERIC DEFAULT 0,
    items JSONB DEFAULT '[]'::jsonb,
    po_filename TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 5. FOLLOWUPS TABLE
CREATE TABLE IF NOT EXISTS followups (
    id TEXT PRIMARY KEY,
    quote_id TEXT REFERENCES quotes(id) UNIQUE,
    owner TEXT,
    next_date DATE,
    logs JSONB DEFAULT '[]'::jsonb,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ENABLE RLS
ALTER TABLE customers ENABLE ROW LEVEL SECURITY;
ALTER TABLE enquiries ENABLE ROW LEVEL SECURITY;
ALTER TABLE quotes ENABLE ROW LEVEL SECURITY;
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE followups ENABLE ROW LEVEL SECURITY;

-- CREATE POLICIES (member = on allow-list OR matches tenant org domain)
DROP POLICY IF EXISTS "Allow company access" ON customers;
DROP POLICY IF EXISTS "Allow company access" ON enquiries;
DROP POLICY IF EXISTS "Allow company access" ON quotes;
DROP POLICY IF EXISTS "Allow company access" ON orders;
DROP POLICY IF EXISTS "Allow company access" ON followups;
CREATE POLICY "Allow member access" ON customers FOR ALL TO authenticated USING (is_app_member()) WITH CHECK (is_app_member());
CREATE POLICY "Allow member access" ON enquiries FOR ALL TO authenticated USING (is_app_member()) WITH CHECK (is_app_member());
CREATE POLICY "Allow member access" ON quotes    FOR ALL TO authenticated USING (is_app_member()) WITH CHECK (is_app_member());
CREATE POLICY "Allow member access" ON orders    FOR ALL TO authenticated USING (is_app_member()) WITH CHECK (is_app_member());
CREATE POLICY "Allow member access" ON followups FOR ALL TO authenticated USING (is_app_member()) WITH CHECK (is_app_member());
  
-- 6. APP SETTINGS
CREATE TABLE IF NOT EXISTS app_settings (
    id TEXT PRIMARY KEY DEFAULT 'config',
    header_url TEXT,
    sig_name TEXT DEFAULT 'Akash Gupta',
    sig_des TEXT DEFAULT 'Rubber Technologist',
    sig_phone TEXT DEFAULT '+91-817171 6630',
    sig_url TEXT,
    bank_name TEXT DEFAULT 'ICICI BANK LTD.',
    bank_acc TEXT DEFAULT '0000000000',
    bank_ifsc TEXT DEFAULT 'ICIC0000000',
    bank_swift TEXT,
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE app_settings ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Allow company access" ON app_settings;
CREATE POLICY "Allow member access" ON app_settings FOR ALL TO authenticated USING (is_app_member()) WITH CHECK (is_app_member());

-- Seed initial config
INSERT INTO app_settings (id) VALUES ('config') ON CONFLICT (id) DO NOTHING;

-- 7. AUTHORIZED SIGNATORIES
CREATE TABLE IF NOT EXISTS authorized_signatories (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    designation TEXT NOT NULL,
    phone TEXT,
    is_default BOOLEAN DEFAULT false,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE authorized_signatories ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Allow company access" ON authorized_signatories;
CREATE POLICY "Allow member access" ON authorized_signatories FOR ALL TO authenticated USING (is_app_member()) WITH CHECK (is_app_member());

-- ============================================================
-- RLS for control tables
-- ============================================================
ALTER TABLE tenant_config         ENABLE ROW LEVEL SECURITY;
ALTER TABLE allowed_users         ENABLE ROW LEVEL SECURITY;
ALTER TABLE install_registrations ENABLE ROW LEVEL SECURITY;

-- tenant_config: any authenticated user may READ (needed at setup/login to
-- learn the org domain); only admins may modify.
DROP POLICY IF EXISTS "tenant read"  ON tenant_config;
DROP POLICY IF EXISTS "tenant write" ON tenant_config;
CREATE POLICY "tenant read"  ON tenant_config FOR SELECT TO authenticated USING (true);
CREATE POLICY "tenant write" ON tenant_config FOR ALL TO authenticated
    USING (EXISTS (SELECT 1 FROM allowed_users WHERE lower(email)=lower(auth.jwt()->>'email') AND role='admin')
           OR NOT (SELECT setup_done FROM tenant_config WHERE id='tenant'))
    WITH CHECK (EXISTS (SELECT 1 FROM allowed_users WHERE lower(email)=lower(auth.jwt()->>'email') AND role='admin')
           OR NOT (SELECT setup_done FROM tenant_config WHERE id='tenant'));

-- allowed_users: members may READ the list; only admins may add/remove.
DROP POLICY IF EXISTS "allow read"  ON allowed_users;
DROP POLICY IF EXISTS "allow admin" ON allowed_users;
CREATE POLICY "allow read"  ON allowed_users FOR SELECT TO authenticated USING (is_app_member());
CREATE POLICY "allow admin" ON allowed_users FOR ALL TO authenticated
    USING (EXISTS (SELECT 1 FROM allowed_users a WHERE lower(a.email)=lower(auth.jwt()->>'email') AND a.role='admin'))
    WITH CHECK (EXISTS (SELECT 1 FROM allowed_users a WHERE lower(a.email)=lower(auth.jwt()->>'email') AND a.role='admin'));

-- install_registrations: any authenticated user may INSERT (one-time at setup);
-- only admins may read them back.
DROP POLICY IF EXISTS "reg insert" ON install_registrations;
DROP POLICY IF EXISTS "reg read"   ON install_registrations;
CREATE POLICY "reg insert" ON install_registrations FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY "reg read"   ON install_registrations FOR SELECT TO authenticated
    USING (EXISTS (SELECT 1 FROM allowed_users WHERE lower(email)=lower(auth.jwt()->>'email') AND role='admin'));

