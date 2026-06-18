import React, { useEffect, useState } from 'react';
import { Loader2, ShieldCheck, Lock } from 'lucide-react';
import { useAppStore } from '../store';
import {
  getTenantConfig, completeSetup, checkAccess, VENDOR_EMAIL, RELABELABLE,
} from '../lib/license';

/**
 * Gates the app after login:
 *  - If setup is not done  -> show the (disclosed, consent-gated) setup wizard.
 *  - If user is allowed    -> render children.
 *  - Otherwise             -> blank "access denied" screen.
 */
export function SetupGuard({ children }: { children: React.ReactNode }) {
  const { user } = useAppStore();
  const [state, setState] = useState<'checking' | 'setup' | 'allowed' | 'denied'>('checking');

  const evaluate = async () => {
    setState('checking');
    const cfg = await getTenantConfig();
    if (!cfg || !cfg.setup_done) { setState('setup'); return; }
    const ok = await checkAccess(user?.email);
    setState(ok ? 'allowed' : 'denied');
  };

  useEffect(() => { if (user) evaluate(); }, [user?.email]);

  if (state === 'checking') {
    return (
      <div className="h-screen w-screen flex items-center justify-center bg-cream">
        <Loader2 size={40} className="text-blk opacity-20 animate-spin" />
      </div>
    );
  }
  if (state === 'setup')  return <SetupWizard email={user?.email ?? ''} onDone={evaluate} />;
  if (state === 'denied') return <AccessDenied email={user?.email ?? ''} />;
  return <>{children}</>;
}

function SetupWizard({ email, onDone }: { email: string; onDone: () => void }) {
  const [step, setStep] = useState<1 | 2>(1);
  const [company, setCompany] = useState('');
  const [domain, setDomain] = useState(email.includes('@') ? email.split('@')[1] : '');
  const [consent, setConsent] = useState(false);
  const [wantRename, setWantRename] = useState(false);
  const [labels, setLabels] = useState<Record<string, string>>(
    Object.fromEntries(RELABELABLE.map(f => [f.key, f.default]))
  );
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  const next = () => {
    setErr(null);
    if (!company.trim()) return setErr('Enter your company name.');
    if (!domain.trim())  return setErr('Enter your organization email domain.');
    if (!consent)        return setErr('You must accept to continue.');
    setStep(2);
  };

  const submit = async () => {
    setErr(null);
    setBusy(true);
    // Only persist labels the admin actually changed from the default.
    const custom: Record<string, string> = {};
    if (wantRename) {
      for (const f of RELABELABLE) {
        const v = labels[f.key]?.trim();
        if (v && v !== f.default) custom[f.key] = v;
      }
    }
    const res = await completeSetup({
      company: company.trim(), orgDomain: domain.trim(), setupEmail: email, labels: custom,
    });
    setBusy(false);
    if (!res.ok) return setErr(res.error || 'Setup failed.');
    onDone();
  };

  return (
    <div className="h-screen w-screen flex items-center justify-center bg-cream p-4">
      <div className="w-full max-w-md bg-white border border-blk/10 rounded-xl p-8 shadow-sm">
        <div className="flex items-center gap-2 mb-1">
          <ShieldCheck size={18} className="text-blk" />
          <h1 className="text-lg font-bold">Welcome to EnqBoss</h1>
        </div>
        <p className="text-[13px] text-blk/60 mb-6">
          Harsh Kashyap welcomes you. Let's set up your workspace. (Step {step} of 2)
        </p>

        {step === 1 && (
          <>
            <label className="block text-[11px] font-mono uppercase tracking-wide text-blk/50 mb-1">Company name</label>
            <input value={company} onChange={e => setCompany(e.target.value)}
              className="w-full mb-4 px-3 py-2 border border-blk/15 rounded text-[14px]" placeholder="Acme Pvt Ltd" />

            <label className="block text-[11px] font-mono uppercase tracking-wide text-blk/50 mb-1">Organization email domain</label>
            <div className="flex items-center mb-4">
              <span className="px-2 py-2 text-blk/40 text-[14px]">@</span>
              <input value={domain} onChange={e => setDomain(e.target.value)}
                className="flex-1 px-3 py-2 border border-blk/15 rounded text-[14px]" placeholder="yourcompany.com" />
            </div>
            <p className="text-[11px] text-blk/40 mb-4">Only people with this email domain (plus anyone you add later) will be able to access data.</p>

            <label className="flex items-start gap-2 mb-5 cursor-pointer">
              <input type="checkbox" checked={consent} onChange={e => setConsent(e.target.checked)} className="mt-1" />
              <span className="text-[12px] text-blk/70 leading-snug">
                EnqBoss is licensed software by <b>Harsh Kashyap</b>. Completing setup registers this
                installation (your company name, domain, admin email, and a random install id) with the
                developer (<b>{VENDOR_EMAIL}</b>). I have read and agree to this.
              </span>
            </label>

            {err && <div className="text-[12px] text-red-600 mb-3">{err}</div>}

            <button type="button" onClick={next}
              className="w-full py-2.5 bg-blk text-white rounded font-medium text-[14px]">
              Continue
            </button>
          </>
        )}

        {step === 2 && (
          <>
            <label className="flex items-center gap-2 mb-3 cursor-pointer">
              <input type="checkbox" checked={wantRename} onChange={e => setWantRename(e.target.checked)} />
              <span className="text-[13px] text-blk/80">Rename field/section names for my business?</span>
            </label>
            <p className="text-[11px] text-blk/40 mb-4">
              Optional. Changes only what these are <b>called</b> in the app (labels). Your data and
              database are unaffected. You can change these later in Settings.
            </p>

            {wantRename && (
              <div className="mb-5 space-y-2">
                {RELABELABLE.map(f => (
                  <div key={f.key} className="flex items-center gap-2">
                    <span className="w-24 text-[11px] font-mono text-blk/50">{f.default}</span>
                    <span className="text-blk/30">→</span>
                    <input
                      value={labels[f.key]}
                      onChange={e => setLabels(prev => ({ ...prev, [f.key]: e.target.value }))}
                      className="flex-1 px-3 py-1.5 border border-blk/15 rounded text-[13px]"
                      placeholder={f.default}
                    />
                  </div>
                ))}
              </div>
            )}

            {err && <div className="text-[12px] text-red-600 mb-3">{err}</div>}

            <div className="flex gap-2">
              <button type="button" onClick={() => { setErr(null); setStep(1); }} disabled={busy}
                className="px-4 py-2.5 border border-blk/15 rounded text-[14px] disabled:opacity-50">
                Back
              </button>
              <button type="button" onClick={submit} disabled={busy}
                className="flex-1 py-2.5 bg-blk text-white rounded font-medium text-[14px] disabled:opacity-50 flex items-center justify-center gap-2">
                {busy && <Loader2 size={15} className="animate-spin" />}
                {busy ? 'Setting up…' : 'Complete setup'}
              </button>
            </div>
          </>
        )}
      </div>
    </div>
  );
}

function AccessDenied({ email }: { email: string }) {
  const { logout } = useAppStore();
  return (
    <div className="h-screen w-screen flex items-center justify-center bg-cream p-4">
      <div className="w-full max-w-sm text-center">
        <Lock size={32} className="mx-auto text-blk/30 mb-4" />
        <h1 className="text-base font-bold mb-2">Access denied</h1>
        <p className="text-[13px] text-blk/60 mb-1">
          <b>{email}</b> isn't authorized for this workspace.
        </p>
        <p className="text-[12px] text-blk/40 mb-6">Ask an administrator to add your email.</p>
        <button type="button" onClick={logout} className="text-[12px] underline text-blk/60">Sign in with a different account</button>
      </div>
    </div>
  );
}
