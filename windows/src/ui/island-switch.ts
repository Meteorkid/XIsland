/** 横向滚动只在浮岛标题/折叠外壳启用；输入区与横向列表由调用方排除。 */
export class IslandSwitchGesture {
  private distance = 0;
  private lastEvent = 0;
  private lastSwitch = -Infinity;
  accept(deltaX: number, deltaY: number, deltaMode: number, now: number, sensitivity: 'low'|'medium'|'high' = 'medium'): boolean {
    if (!Number.isFinite(deltaX) || !Number.isFinite(deltaY) || !Number.isFinite(now)) return false;
    if (Math.abs(deltaX) <= Math.abs(deltaY) || now - this.lastSwitch < 1200) { this.distance = 0; return false; }
    if (now - this.lastEvent > 220 || Math.sign(this.distance) !== Math.sign(deltaX)) this.distance = 0;
    this.lastEvent = now;
    this.distance += deltaX * (deltaMode === 1 ? 16 : deltaMode === 2 ? 120 : 1);
    if (Math.abs(this.distance) < ({low:120,medium:80,high:45}[sensitivity])) return false;
    this.distance = 0; this.lastSwitch = now; return true;
  }
}
