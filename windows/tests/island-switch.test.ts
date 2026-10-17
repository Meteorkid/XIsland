import assert from 'node:assert/strict';
import { test } from 'node:test';
import { IslandSwitchGesture } from '../src/ui/island-switch';
test('共享灵敏度采用低中高三个不同阈值', () => {
  assert.equal(new IslandSwitchGesture().accept(50,0,0,100,'high'),true);
  assert.equal(new IslandSwitchGesture().accept(50,0,0,100,'medium'),false);
  assert.equal(new IslandSwitchGesture().accept(90,0,0,100,'low'),false);
  assert.equal(new IslandSwitchGesture().accept(125,0,0,100,'low'),true);
});
test('横向手势累积并限频，普通垂直滚动不触发', () => {
  const gesture = new IslandSwitchGesture();
  assert.equal(gesture.accept(30, 2, 0, 100), false);
  assert.equal(gesture.accept(55, 2, 0, 160), true);
  assert.equal(gesture.accept(100, 0, 0, 200), false);
  assert.equal(gesture.accept(20, 90, 0, 1500), false);
  assert.equal(gesture.accept(-90, 2, 0, 1600), true);
});
test('分离或相反方向手势不拼接，非法数据拒绝', () => {
  const gesture = new IslandSwitchGesture();
  assert.equal(gesture.accept(50, 0, 0, 0), false);
  assert.equal(gesture.accept(50, 0, 0, 400), false);
  assert.equal(gesture.accept(-50, 0, 0, 420), false);
  assert.equal(gesture.accept(Number.NaN, 0, 0, 430), false);
  assert.equal(gesture.accept(-2, 0, 1, 440), true);
});
