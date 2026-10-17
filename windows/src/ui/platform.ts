import type { Decision, DIResponse, Session } from '../core/index';
import type { ManagedAgent } from '../adapters/registry';
import type { ClientDiscovery } from '../integrations/discovery';
import type { HookTrustSnapshot } from '../integrations/codex-trust';
import type { SoundEvent } from './audio';
import type { WorkBuddyExportResult, WorkBuddySetupStatus } from '../integrations/workbuddy-plugin';
import type { KiroExportResult, KiroSetupStatus } from '../integrations/kiro-plugin';
import type { IntegrationOperation, InstallationSummary, applyIntegration, getIntegrationStatus } from '../integrations/installer';
import type { SetupSnapshot } from '../integrations/setup-coordinator';

export type IntegrationAgent = ManagedAgent;
export type { IntegrationOperation };
export type IntegrationStatus = Omit<Awaited<ReturnType<typeof getIntegrationStatus>>, 'installed' | 'managedHandlers' | 'agent'> & {
  agent: IntegrationAgent;
  client?: ClientDiscovery;
  trust?: HookTrustSnapshot;
  activity?: { event: string; receivedAt: number };
  foreignPlugin?: boolean;
  updateAvailable?: boolean;
  installed: boolean | null;
  managedHandlers: number | null;
  configurationKnown?: boolean;
  reason?: string;
};
export type IntegrationPlanSummary = Omit<InstallationSummary, 'agent'> & { agent: IntegrationAgent };
export type IntegrationApplyResult = Omit<Awaited<ReturnType<typeof applyIntegration>>, 'agent'> & { agent: IntegrationAgent; backupId?: string };
export interface IntegrationPlatform {
  setup?: {
    snapshot(): Promise<SetupSnapshot | null>;
    subscribe(listener: (snapshot: SetupSnapshot) => void): Promise<() => void>;
    refresh(prepareAutomatically: boolean): Promise<void>;
    setEnabled(agent: IntegrationAgent, enabled: boolean): Promise<void>;
    presented(): Promise<void>;
  };
  exportWorkBuddy?(): Promise<WorkBuddyExportResult>;
  workBuddyStatus?(): Promise<WorkBuddySetupStatus>;
  prepareWorkBuddy?(): Promise<WorkBuddyExportResult>;
  openWorkBuddyFolder?(path: string): Promise<void>;
  kiroStatus?(): Promise<KiroSetupStatus>;
  prepareKiro?(): Promise<KiroExportResult>;
  status(agent: IntegrationAgent): Promise<IntegrationStatus>;
  plan(agent: IntegrationAgent, operation: IntegrationOperation): Promise<IntegrationPlanSummary>;
  apply(agent: IntegrationAgent, operation: IntegrationOperation, revision: string): Promise<IntegrationApplyResult>;
}

export type IslandTheme = 'dark' | 'light' | 'system';
export type IslandLanguage = 'system' | 'zh' | 'en' | 'ja' | 'ko' | 'fr';
export type AnimationIntensity = 'low' | 'medium' | 'high';
export type JellyIntensity = 'weak' | 'medium' | 'strong';

export interface IslandSettings {
  theme: IslandTheme;
  language: IslandLanguage;
  animationIntensity: AnimationIntensity;
  jellyIntensity: JellyIntensity;
  disableAnimations: boolean;
  soundEnabled: boolean;
  soundVolume: number;
  eventSounds: Record<SoundEvent, boolean>;
  quietHours: boolean;
  quietStart: string;
  quietEnd: string;
  hoverToExpand: boolean;
  showTicker: boolean;
  reduceMotion: boolean;
  autoHideSeconds: number;
  hideInFullscreen: boolean;
  followPointer: boolean;
  collapsedWidth: number;
  collapsedHeight: number;
  panelWidth: number;
}

export interface IslandPlatform {
  getIslandPreferences?(): Promise<IslandLinkPreferences>;
  setIslandPreferences?(preferences: IslandLinkPreferences): Promise<IslandLinkPreferences>;
  islandPeerStatus?(): Promise<{ installed: boolean; running: boolean; compatible: boolean; detail: string }>;
  switchIsland?(): Promise<void>;
  resize(width: number, height: number, expanded: boolean): Promise<void>;
  focus(): Promise<void>;
  respond(requestId: string, response: DIResponse): Promise<void>;
  jump(session: Session): Promise<void>;
  exportHistory(content: string): Promise<void>;
  settingsChanged?(settings: IslandSettings): Promise<void>;
  notify?(kind: SoundEvent): void;
  nativeAutoplayAudio?: boolean;
  previewSound?(event: SoundEvent): Promise<void>;
  /** 浏览器预览必须显式标记，不能伪装成已连接真实会话。 */
  preview?: boolean;
  capabilities?: { fullscreenHiding?: boolean; monitorFollowing?: boolean };
  openSettings?(pane: string): Promise<void>;
  closeSettings?(): Promise<void>;
  deleteHistory?(sessionId: string): Promise<void>;
  clearHistory?(): Promise<void>;
  preferencesWindow?: boolean;
  initialSettingsPane?: string;
  integrations?: IntegrationPlatform;
}

export interface IslandLinkPreferences {
  swipeEnabled: boolean;
  sensitivity: 'low' | 'medium' | 'high';
  startupDisplay: 'lastUsed' | 'xnook' | 'xisland';
}

export type IslandDecision = Decision;
