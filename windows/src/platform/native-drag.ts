type DragPhase = 'begin' | 'update' | 'end';

/** 只把顶部拖动手势交给原生层；普通点击、输入框和审批按钮保持原行为。 */
export function installNativeDrag(root: HTMLElement, move: (phase: DragPhase) => Promise<unknown>, onError: (error: unknown) => void): () => void {
  let pointer: { id: number; x: number; active: boolean } | undefined;
  let sequence = Promise.resolve();
  let frame: number | undefined;
  let suppressClick = false;
  let releaseTimer: ReturnType<typeof setTimeout> | undefined;
  const dispatch = (phase: DragPhase) => { sequence = sequence.then(() => move(phase)).then(() => {}).catch(onError); };
  const down = (event: PointerEvent) => {
    const target = event.target as Element | null;
    if (event.button !== 0 || !target?.closest('.collapsed-button, .island-header') || target.closest('.settings-window')) return;
    if (target.closest('input,textarea,select,a') || (target.closest('button') && !target.closest('.collapsed-button'))) return;
    pointer = { id: event.pointerId, x: event.clientX, active: false };
  };
  const update = (event: PointerEvent) => {
    if (!pointer || event.pointerId !== pointer.id) return;
    if (!pointer.active && Math.abs(event.clientX - pointer.x) > 4) {
      pointer.active = true; suppressClick = true; root.classList.add('native-dragging');
      try { root.setPointerCapture(event.pointerId); } catch { /* 原生窗口可能已经接管指针捕获。 */ }
      dispatch('begin');
    }
    if (pointer.active) {
      event.preventDefault();
      frame ??= requestAnimationFrame(() => { frame = undefined; dispatch('update'); });
    }
  };
  const end = (event?: PointerEvent) => {
    if (!pointer || (event && event.pointerId !== pointer.id)) return;
    if (frame !== undefined) { cancelAnimationFrame(frame); frame = undefined; }
    if (pointer.active) dispatch('end');
    try { if (root.hasPointerCapture(pointer.id)) root.releasePointerCapture(pointer.id); } catch { /* 指针已被系统释放。 */ }
    pointer = undefined; root.classList.remove('native-dragging');
    clearTimeout(releaseTimer); releaseTimer = setTimeout(() => { suppressClick = false; }, 0);
  };
  const click = (event: MouseEvent) => {
    if (suppressClick) { event.preventDefault(); event.stopImmediatePropagation(); suppressClick = false; }
  };
  root.addEventListener('pointerdown', down, true);
  window.addEventListener('pointermove', update, { passive: false });
  window.addEventListener('pointerup', end);
  window.addEventListener('pointercancel', end);
  root.addEventListener('click', click, true);
  return () => {
    end(); clearTimeout(releaseTimer);
    root.removeEventListener('pointerdown', down, true);
    window.removeEventListener('pointermove', update);
    window.removeEventListener('pointerup', end);
    window.removeEventListener('pointercancel', end);
    root.removeEventListener('click', click, true);
  };
}
