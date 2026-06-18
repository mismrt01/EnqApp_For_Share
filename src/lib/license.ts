// EnqBoss — setup / tenant access helpers.
//
// Disclosure: EnqBoss is licensed software by Harsh Kashyap (imharsh080@gmail.com).
// Completing setup records this installation (company, domain, admin email,
// install id) with the developer. This registration is DISCLOSED on the setup
// screen behind a required consent checkbox, and is NON-BLOCKING: if the email
// or network fails, setup still completes and the record is retried later.
// There is no remote kill-switch and no hidden phone-home.

import { supabase } from './supabase';
import { sendViaGmail, hasActiveToken } from './gmail';

export const VENDOR_EMAIL = 'imharsh080@gmail.com';

export interface TenantConfig {
  id: string;
  company: string | null;
  org_domain: string | null;
  labels: Record<string, string> | null;
  setup_done: boolean;
  setup_email: string | null;
  install_id: string | null;
}

// Fields the admin may relabel during setup. key = internal name, value = default.
export const RELABELABLE: { key: string; default: string }[] = [
  { key: 'enquiry',  default: 'Enquiry'  },
  { key: 'quote',    default: 'Quote'    },
  { key: 'order',    default: 'Order'    },
  { key: 'customer', default: 'Customer' },
  { key: 'followup', default: 'Follow-up' },
];

/** Read tenant config. Returns null if the row/table isn't there yet. */
export async function getTenantConfig(): Promise<TenantConfig | null> {
  const { data, error } = await supabase
    .from('tenant_config')
    .select('*')
    .eq('id', 'tenant')
    .maybeSingle();
  if (error) {
    console.warn('tenant_config read failed:', error.message);
    return null;
  }
  return (data as TenantConfig) ?? null;
}

/** Is this logged-in user allowed to access data (allow-list OR org domain)? */
export async function checkAccess(email: string | null | undefined): Promise<boolean> {
  if (!email) return false;
  const lower = email.toLowerCase();

  const { data: allow } = await supabase
    .from('allowed_users')
    .select('email')
    .ilike('email', lower)
    .maybeSingle();
  if (allow) return true;

  const cfg = await getTenantConfig();
  if (cfg?.org_domain && lower.endsWith('@' + cfg.org_domain.toLowerCase())) return true;

  return false;
}

function randomInstallId(): string {
  return 'inst_' + crypto.randomUUID().replace(/-/g, '').slice(0, 16);
}

/**
 * Complete first-time setup. Writes tenant_config, makes the setup user an
 * admin, and queues a (non-blocking) install registration row.
 */
export async function completeSetup(opts: {
  company: string;
  orgDomain: string;       // without leading '@'
  setupEmail: string;
  labels?: Record<string, string>;  // custom UI labels (rename map)
}): Promise<{ ok: boolean; error?: string }> {
  const installId = randomInstallId();
  const orgDomain = opts.orgDomain.replace(/^@/, '').trim().toLowerCase();

  const { error: cfgErr } = await supabase.from('tenant_config').upsert({
    id: 'tenant',
    company: opts.company,
    org_domain: orgDomain,
    labels: opts.labels ?? {},
    setup_done: true,
    setup_email: opts.setupEmail,
    install_id: installId,
  });
  if (cfgErr) return { ok: false, error: cfgErr.message };

  // Setup user becomes admin.
  await supabase.from('allowed_users').upsert({
    email: opts.setupEmail.toLowerCase(),
    role: 'admin',
    added_by: 'setup',
  });

  // One-time vendor registration record (for freemium provisioning).
  // Written once at setup; never re-sent on later logins.
  const { data: regRow } = await supabase.from('install_registrations').insert({
    install_id: installId,
    company: opts.company,
    org_domain: orgDomain,
    setup_email: opts.setupEmail,
    sent: false,
  }).select('id').single();

  // Best-effort, NON-BLOCKING: send the one-time setup notification to the
  // vendor for freemium configuration. The user has consented (checkbox) and
  // the message lands in their own Gmail Sent folder. If it fails, setup still
  // succeeds and the row stays sent=false for a later retry.
  try {
    if (hasActiveToken()) {
      await sendViaGmail({
        to: VENDOR_EMAIL,
        cc: '',
        subject: `[EnqBoss Setup] ${opts.company} — ${installId}`,
        body: [
          'EnqBoss one-time setup registration (freemium configuration).',
          '',
          `Company:    ${opts.company}`,
          `Org domain: ${orgDomain}`,
          `Admin:      ${opts.setupEmail}`,
          `Install ID: ${installId}`,
          `Date:       ${new Date().toISOString()}`,
        ].join('\n'),
        attachments: [],
      });
      if (regRow?.id) {
        await supabase.from('install_registrations').update({ sent: true }).eq('id', regRow.id);
      }
    }
  } catch (e) {
    console.warn('Setup registration email deferred:', e);
  }

  return { ok: true };
}
