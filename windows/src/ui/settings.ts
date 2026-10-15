import type { IslandSettings } from './platform';
import { defaultEventSounds, SOUND_EVENTS } from './audio';
export { IslandSound } from './audio';

export const DEFAULT_SETTINGS: IslandSettings = {
  theme: 'dark', language: 'system', animationIntensity: 'medium', jellyIntensity: 'medium', disableAnimations: false,
  soundEnabled: true, soundVolume: .5, eventSounds: defaultEventSounds(), quietHours: false, quietStart: '22:00', quietEnd: '07:00',
  hoverToExpand: false, showTicker: true, reduceMotion: false, autoHideSeconds: 10,
  hideInFullscreen: false, followPointer: true, collapsedWidth: 261.34, collapsedHeight: 38.77, panelWidth: 380,
};
export const SETTINGS_KEY = 'xisland.windows.settings.v1';

export function loadSettings(): IslandSettings {
  return normalizeSettings(JSON.parse(localStorage.getItem(SETTINGS_KEY) ?? '{}'));
}

export function normalizeSettings(value: unknown): IslandSettings {
  if (!value || typeof value !== 'object') return { ...DEFAULT_SETTINGS, eventSounds: defaultEventSounds() };
  const settings = { ...DEFAULT_SETTINGS, eventSounds: defaultEventSounds() };
  const input = value as Record<string, unknown>;
  if (typeof input.soundVolume === 'number' && Number.isFinite(input.soundVolume)) settings.soundVolume = Math.min(1, Math.max(0, input.soundVolume));
  if (input.eventSounds && typeof input.eventSounds === 'object') {
    const events = input.eventSounds as Record<string, unknown>;
    for (const event of SOUND_EVENTS) if (typeof events[event] === 'boolean') settings.eventSounds[event] = events[event];
  }
  for (const key of ['soundEnabled', 'quietHours', 'hoverToExpand', 'showTicker', 'reduceMotion', 'hideInFullscreen', 'followPointer', 'disableAnimations'] as const) {
    if (typeof input[key] === 'boolean') settings[key] = input[key];
  }
  if (input.theme === 'dark' || input.theme === 'light' || input.theme === 'system') settings.theme = input.theme;
  if (['system', 'zh', 'en', 'ja', 'ko', 'fr'].includes(String(input.language))) settings.language = input.language as IslandSettings['language'];
  if (['low', 'medium', 'high'].includes(String(input.animationIntensity))) settings.animationIntensity = input.animationIntensity as IslandSettings['animationIntensity'];
  if (['weak', 'medium', 'strong'].includes(String(input.jellyIntensity))) settings.jellyIntensity = input.jellyIntensity as IslandSettings['jellyIntensity'];
  for (const key of ['quietStart', 'quietEnd'] as const) {
    if (typeof input[key] === 'string' && /^([01]\d|2[0-3]):[0-5]\d$/.test(input[key])) settings[key] = input[key];
  }
  for (const [key, min, max] of [['autoHideSeconds', 0, 300], ['collapsedWidth', 200, 400], ['collapsedHeight', 30, 60], ['panelWidth', 320, 520]] as const) {
    if (typeof input[key] === 'number' && Number.isFinite(input[key])) settings[key] = Math.min(max, Math.max(min, input[key]));
  }
  return settings;
}
export function saveSettings(settings: IslandSettings): void { localStorage.setItem(SETTINGS_KEY, JSON.stringify(settings)); }

export function isQuiet(settings: IslandSettings, now = new Date()): boolean {
  if (!settings.quietHours) return false;
  const current = now.getHours() * 60 + now.getMinutes();
  const minutes = (value: string) => Number(value.slice(0, 2)) * 60 + Number(value.slice(3));
  const start = minutes(settings.quietStart), end = minutes(settings.quietEnd);
  return start < end ? current >= start && current < end : start > end && (current >= start || current < end);
}
