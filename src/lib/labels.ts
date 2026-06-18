// Reads tenant custom labels (set during setup) and resolves a label by key.
// Falls back to the built-in default when no custom label exists.
import { RELABELABLE, getTenantConfig } from './license';

let cache: Record<string, string> | null = null;

const defaults: Record<string, string> =
  Object.fromEntries(RELABELABLE.map(f => [f.key, f.default]));

/** Load custom labels once (call after login). */
export async function loadLabels(): Promise<Record<string, string>> {
  const cfg = await getTenantConfig();
  cache = { ...defaults, ...(cfg?.labels ?? {}) };
  return cache;
}

/** Resolve a label by key, e.g. label('enquiry') -> 'RFQ'. */
export function label(key: string): string {
  return cache?.[key] ?? defaults[key] ?? key;
}
