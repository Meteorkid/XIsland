import type { Decision, DIResponse, Session } from '../core/index';
import type { ConfigurableAgent } from '../adapters/registry';
import type { SoundEvent } from './audio';
import type { WorkBuddyExportResult } from '../integrations/workbuddy-plugin';
import type { IntegrationOperation, InstallationSummary, applyIntegration, getIntegrationStatus } from '../integrations/installer';

export type IntegrationAgent = ConfigurableAgent;
export type { IntegrationOperation };
export type IntegrationStatus = Omit<Awaited<ReturnType<typeof getIntegrationStatus>>, 'installed' | 'managedHandlers'> & {
  installed: boolean | null;
  managedHandlers: number | null;
  configurationKnown?: boolean;
  reason?: string;
};
export type IntegrationPlanSummary = InstallationSummary;
export type IntegrationApplyResult = Awaited<ReturnType<typeof applyIntegration>>;
export interface IntegrationPlatform {
  exportWorkBuddy?(): Promise<WorkBuddyExportResult>;
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

export type IslandDecision = Decision;
