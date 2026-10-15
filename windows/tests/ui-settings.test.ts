import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFileSync } from 'node:fs';
import { DEFAULT_SETTINGS, isQuiet, normalizeSettings } from '../src/ui/settings';
import { messages, resolveLanguage, translate } from '../src/ui/i18n';
import { ANIMATION_PRESETS, JELLY_PRESETS, magneticOffset, motionPolicy, springProgress } from '../src/ui/motion';

test('语言匹配地区及系统优先顺序，显式选择不被系统覆盖',()=>{
  assert.equal(resolveLanguage('system',['de-DE','ko-KR','en-US']),'ko');
  assert.equal(resolveLanguage('system',['zh-Hant-TW']),'zh');
  assert.equal(resolveLanguage('system',['de-DE']),'en');
  assert.equal(resolveLanguage('fr',['ja-JP']),'fr');
});

test('语言字典覆盖界面文案，四种翻译均存在且模板参数保留',()=>{
  for(const filename of ['index.ts','components.ts','integration-controls.ts']){
    const source=readFileSync(new URL(`../src/ui/${filename}`,import.meta.url),'utf8');
    for(const match of source.matchAll(/\bt\('([^']+)'/g))assert.ok(messages[match[1]],`缺少消息: ${match[1]}`);
  }
  for(const[key,translations]of Object.entries(messages)){
    assert.equal(translations.length,4);
    const parameters=[...key.matchAll(/\{\w+\}/g)].map(match=>match[0]).sort();
    for(const translation of translations){assert.ok(translation.trim());assert.deepEqual([...translation.matchAll(/\{\w+\}/g)].map(match=>match[0]).sort(),parameters);}
  }
  assert.equal(translate('{count} 项待处理','en',{count:3}),'3 pending');
  assert.equal(translate('允许','fr'),'Autoriser');
});

test('旧设置迁移、非法枚举与超范围尺寸使用受控默认值',()=>{
  const value=normalizeSettings({language:'xx',animationIntensity:'extreme',jellyIntensity:9,disableAnimations:true,panelWidth:999,collapsedHeight:NaN});
  assert.equal(value.language,'system');assert.equal(value.animationIntensity,'medium');assert.equal(value.jellyIntensity,'medium');
  assert.equal(value.disableAnimations,true);assert.equal(value.panelWidth,520);assert.equal(value.collapsedHeight,38.77);
  assert.deepEqual(normalizeSettings(null),DEFAULT_SETTINGS);
});

test('减少动态效果采用low离散过渡，关闭动画停止全部过渡',()=>{
  const reduced=motionPolicy({...DEFAULT_SETTINGS,animationIntensity:'high'},true);
  assert.equal(reduced.preset,ANIMATION_PRESETS.low);assert.equal(reduced.continuous,false);assert.equal(reduced.disabled,false);
  const disabled=motionPolicy({...DEFAULT_SETTINGS,disableAnimations:true},false);
  assert.equal(disabled.disabled,true);assert.equal(disabled.continuous,false);
  assert.deepEqual(ANIMATION_PRESETS.medium.expand,[.4,.82]);assert.equal(ANIMATION_PRESETS.medium.finish,.45);
  assert.deepEqual(JELLY_PRESETS.strong,{xPop:.9,xSettle:.96,yPop:1.4,ySettle:1.12});
});

test('磁吸有范围与有界输出，弹簧从零收敛到目标',()=>{
  assert.equal(magneticOffset(0,0),0);assert.equal(magneticOffset(80,0),0);assert.equal(magneticOffset(NaN,10),0);
  assert.equal(magneticOffset(40,0),3);assert.equal(magneticOffset(-40,0),-3);
  assert.equal(springProgress(0,.4,.82),0);assert.ok(Math.abs(springProgress(2,.4,.82)-1)<.001);
});

test('跨午夜勿扰、同时间空时段与开关状态',()=>{
  const settings={...DEFAULT_SETTINGS,quietHours:true};
  assert.equal(isQuiet(settings,new Date(2026,9,14,23,0)),true);assert.equal(isQuiet(settings,new Date(2026,9,14,7,0)),false);
  assert.equal(isQuiet({...settings,quietStart:'08:00',quietEnd:'08:00'},new Date()),false);
  assert.equal(isQuiet({...settings,quietHours:false},new Date(2026,9,14,23,0)),false);
});
