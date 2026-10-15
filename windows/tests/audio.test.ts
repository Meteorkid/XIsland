import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { SAMPLE_RATE, SOUND_EVENTS, SOUND_NOTES, SOUND_LABELS, synthesizeSound, IslandSound } from '../src/ui/audio';
import { normalizeSettings, DEFAULT_SETTINGS } from '../src/ui/settings';
import { messages } from '../src/ui/i18n';

test('all eleven sound melodies match the current macOS source including silence and duration', () => {
  const swift = readFileSync(new URL('../../Sources/DynamicIsland/Managers/AudioEngine.swift', import.meta.url), 'utf8');
  const names = new Map([...swift.slice(0, swift.indexOf('// MARK: - 音频引擎')).matchAll(/case\s+(\w+)\s*=\s*"([^"]+)"/g)].map(match => [match[1], match[2]]));
  assert.equal(names.size, 11);
  const body = swift.slice(swift.indexOf('private func synthNotes('), swift.indexOf('private func playToneSequence('));
  const found = new Set<string>();
  for (const match of body.matchAll(/case\s+\.(\w+):\s*return\s*\[([\s\S]*?)\]/g)) {
    const name = names.get(match[1]) as typeof SOUND_EVENTS[number];
    const notes = [...match[2].matchAll(/SynthNote\(frequency:\s*([\d.]+),\s*duration:\s*([\d.]+)\)/g)].map(note => [Number(note[1]), Number(note[2])]);
    assert.deepEqual(SOUND_NOTES[name], notes, name); found.add(name);
    assert.ok(messages[SOUND_LABELS[name]], `Missing translations for ${name}`);
  }
  assert.deepEqual([...found].sort(), [...SOUND_EVENTS].sort());
});

test('PCM is mono 44.1 kHz square wave with bounded fade and explicit silent notes', () => {
  assert.equal(SAMPLE_RATE, 44100);
  const samples = synthesizeSound('permission_request', .5);
  assert.equal(samples.length, Math.trunc(44100*.06)*2 + Math.trunc(44100*.04)*2 + Math.trunc(44100*.1));
  assert.equal(Math.abs(samples[0]), 0);
  assert.equal(Math.abs(samples[100]), .125);
  assert.ok(Math.abs(samples[50]) <= .0625);
  const silenceStart = Math.trunc(44100*.06), silenceEnd = silenceStart + Math.trunc(44100*.04);
  assert.ok(samples.slice(silenceStart, silenceEnd).every(value => value === 0));
  assert.ok(samples.every(value => Number.isFinite(value) && Math.abs(value) <= .125));
  assert.ok(synthesizeSound('error', 0).every(value => value === 0));
  for (const volume of [-1, 2, NaN]) assert.throws(() => synthesizeSound('error', volume));
});

test('audio preferences preserve zero volume, default event switches and independent objects', () => {
  const settings = normalizeSettings({ soundVolume: 0, eventSounds: { tool_start: true, error: false, question: 'bad' } });
  assert.equal(settings.soundVolume, 0); assert.equal(settings.eventSounds.tool_start, true);
  assert.equal(settings.eventSounds.error, false); assert.equal(settings.eventSounds.question, true);
  assert.equal(DEFAULT_SETTINGS.eventSounds.session_start, false);
  assert.equal(DEFAULT_SETTINGS.eventSounds.context_compacting, false);
  const other = normalizeSettings(null); other.eventSounds.error = false;
  assert.equal(normalizeSettings(null).eventSounds.error, true);
});

test('reused audio engine updates mixer volume and never initializes until explicitly primed', async () => {
  const old = Object.getOwnPropertyDescriptor(globalThis, 'AudioContext');
  const volumes: number[] = [], rates: number[] = []; let contexts = 0, stops = 0;
  class Context {
    state = 'running'; destination = {};
    constructor() { contexts++; }
    createBuffer(channels: number, frames: number, rate: number) { assert.equal(channels, 1); rates.push(rate); const data = new Float32Array(frames); return { getChannelData: () => data }; }
    createBufferSource() { return { buffer: undefined, onended: undefined, connect() {}, disconnect() {}, start() {}, stop() { stops++; } }; }
    createGain() { const gain = { value: 0 }; Object.defineProperty(gain, 'value', { set: (value: number) => volumes.push(value) }); return { gain, connect() {}, disconnect() {} }; }
    async close() { this.state = 'closed'; }
  }
  try {
    Object.defineProperty(globalThis, 'AudioContext', { configurable: true, value: Context });
    const sound = new IslandSound(); assert.equal(contexts, 0); assert.equal(sound.play('session_end'), false);
    assert.equal(await sound.prime(), true); sound.play('approved', .5); sound.play('denied', .2);
    assert.equal(contexts, 1); assert.deepEqual(volumes, [.5, .2]); assert.deepEqual(rates, [44100, 44100]);
    assert.equal(stops, 1); sound.destroy(); assert.equal(stops, 2);
  } finally {
    if (old) Object.defineProperty(globalThis, 'AudioContext', old); else Reflect.deleteProperty(globalThis, 'AudioContext');
  }
});
