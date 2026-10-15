export const SOUND_EVENTS = ['session_start', 'session_end', 'permission_request', 'question', 'plan_review',
  'approved', 'denied', 'answered', 'tool_start', 'context_compacting', 'error'] as const;
export type SoundEvent = typeof SOUND_EVENTS[number];
export const SAMPLE_RATE = 44100;
type Note = readonly [frequency: number, duration: number];

/** 与 macOS AudioEngine.toneSequence 保持相同旋律和静音段。 */
export const SOUND_NOTES: Record<SoundEvent, readonly Note[]> = {
  session_start: [[523.25, .08], [659.25, .08], [783.99, .12]],
  session_end: [[783.99, .1], [659.25, .1], [523.25, .15]],
  permission_request: [[880, .06], [0, .04], [880, .06], [0, .04], [1108.73, .1]],
  question: [[659.25, .1], [783.99, .15]],
  plan_review: [[440, .08], [523.25, .08], [659.25, .12]],
  approved: [[523.25, .06], [783.99, .12]],
  denied: [[440, .1], [349.23, .15]],
  answered: [[659.25, .08], [523.25, .1]],
  tool_start: [[587.33, .05], [698.46, .07]],
  context_compacting: [[392, .06], [523.25, .06], [392, .06]],
  error: [[220, .15], [0, .05], [220, .15]],
};
export const SOUND_LABELS: Record<SoundEvent, string> = {
  session_start: '任务开始', session_end: '任务完成', permission_request: '需要授权', question: '提出问题',
  plan_review: '计划审核', approved: '已允许', denied: '已拒绝', answered: '已回答', tool_start: '工具运行',
  context_compacting: '压缩上下文', error: '发生错误',
};
export function defaultEventSounds(): Record<SoundEvent, boolean> {
  return Object.fromEntries(SOUND_EVENTS.map(event => [event, !['session_start', 'tool_start', 'context_compacting'].includes(event)])) as Record<SoundEvent, boolean>;
}

export function synthesizeSound(event: SoundEvent, volume: number): Float32Array {
  if (!SOUND_EVENTS.includes(event) || !Number.isFinite(volume) || volume < 0 || volume > 1) throw new Error('Invalid sound parameters');
  const notes = SOUND_NOTES[event];
  const result = new Float32Array(notes.reduce((count, note) => count + Math.trunc(SAMPLE_RATE * note[1]), 0));
  let offset = 0;
  for (const [frequency, duration] of notes) {
    const frames = Math.trunc(SAMPLE_RATE * duration), fade = Math.min(100, Math.trunc(frames / 4));
    if (frequency > 0) for (let sample = 0; sample < frames; sample++) {
      const envelope = sample < fade ? sample / fade : sample > frames - fade ? (frames - sample) / fade : 1;
      const square = Math.sin(2 * Math.PI * frequency * sample / SAMPLE_RATE) > 0 ? 1 : -1;
      result[offset + sample] = square * envelope * volume * .25;
    }
    offset += frames;
  }
  return result;
}

export class IslandSound {
  private context?: AudioContext;
  private source?: AudioBufferSourceNode;
  private gain?: GainNode;

  async prime(): Promise<boolean> {
    try {
      this.context ??= new AudioContext({ sampleRate: SAMPLE_RATE });
      if (this.context.state === 'suspended') await this.context.resume();
      return this.context.state === 'running';
    } catch { return false; }
  }

  play(event: SoundEvent, volume = .5): boolean {
    const context = this.context;
    if (!context || context.state !== 'running') return false;
    this.source?.stop(); this.source?.disconnect(); this.gain?.disconnect();
    const samples = synthesizeSound(event, volume);
    const buffer = context.createBuffer(1, samples.length, SAMPLE_RATE);
    buffer.getChannelData(0).set(samples);
    const source = context.createBufferSource(), gain = context.createGain();
    source.buffer = buffer;
    // Mac 同时使用 PCM 音量和 mixer 音量；每次更新 mixer，避免复用引擎时仍使用旧值。
    gain.gain.value = volume;
    source.connect(gain); gain.connect(context.destination);
    source.onended = () => {
      source.disconnect(); gain.disconnect();
      if (this.source === source) { this.source = undefined; this.gain = undefined; }
    };
    this.source = source; this.gain = gain; source.start(); return true;
  }

  destroy(): void {
    this.source?.stop(); this.source?.disconnect(); this.gain?.disconnect();
    if (this.context) void this.context.close().catch(() => {});
    this.context = undefined; this.source = undefined; this.gain = undefined;
  }
}
