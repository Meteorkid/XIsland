import { type ManagedAgent, type ConfigurableAgent } from '../adapters/registry';
import { applyIntegration, getIntegrationStatus, planIntegration, type IntegrationOperation } from './installer';
import { applyOpenCodeIntegration, getOpenCodeStatus, planOpenCodeIntegration } from './opencode-installation';
import { applyKimiCodeIntegration, getKimiCodeStatus, planKimiCodeIntegration } from './kimi-installation';
import { decorateIntegrationStatus } from './connection-health';
import { getCopilotStatus, planCopilotIntegration, applyCopilotIntegration } from './copilot-installation';
import { getPiStatus, planPiIntegration, applyPiIntegration } from './pi-installation';

/** 裸状态供事件回执绑定使用，不执行客户端探测或信任查询。 */
export async function readManagedStatus(agent: ManagedAgent) {
  if (agent === 'opencode') return getOpenCodeStatus();
  if (agent === 'kimi_code') return getKimiCodeStatus();
  if (agent === 'copilot_cli') return getCopilotStatus();
  if (agent === 'pi') return getPiStatus();
  return getIntegrationStatus(agent as ConfigurableAgent);
}

export async function integrationService(agent: ManagedAgent, action: 'status' | 'plan' | 'apply', operation: IntegrationOperation, revision: string) {
  if (action === 'status') return decorateIntegrationStatus(await readManagedStatus(agent));
  if (agent === 'opencode') return action === 'plan' ? planOpenCodeIntegration(operation) : applyOpenCodeIntegration(operation, revision);
  if (agent === 'kimi_code') return action === 'plan' ? planKimiCodeIntegration(operation) : applyKimiCodeIntegration(operation, revision);
  if (agent === 'copilot_cli') return action === 'plan' ? planCopilotIntegration(operation) : applyCopilotIntegration(operation, revision);
  if (agent === 'pi') return action === 'plan' ? planPiIntegration(operation) : applyPiIntegration(operation, revision);
  return action === 'plan' ? planIntegration(agent, operation) : applyIntegration(agent, operation, revision);
}
