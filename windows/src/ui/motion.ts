import type { AnimationIntensity, IslandSettings, JellyIntensity } from './platform';

export const ANIMATION_PRESETS = {
  low: { expand: [.28,.92], collapse: [.24,.90], fade: .14, start: .02, reveal: .08, finish: .28 },
  medium: { expand: [.40,.82], collapse: [.35,.80], fade: .20, start: .05, reveal: .12, finish: .45 },
  high: { expand: [.50,.74], collapse: [.44,.72], fade: .28, start: .07, reveal: .16, finish: .55 },
} as const;
export const JELLY_PRESETS = {
  weak: { xPop: .97, xSettle: .99, yPop: 1.10, ySettle: 1.03 },
  medium: { xPop: .94, xSettle: .98, yPop: 1.25, ySettle: 1.08 },
  strong: { xPop: .90, xSettle: .96, yPop: 1.40, ySettle: 1.12 },
} satisfies Record<JellyIntensity, { xPop: number; xSettle: number; yPop: number; ySettle: number }>;

export function motionPolicy(settings: Pick<IslandSettings,'reduceMotion'|'disableAnimations'|'animationIntensity'>, systemReduceMotion: boolean) {
  const reduced = settings.reduceMotion || systemReduceMotion;
  const intensity: AnimationIntensity = reduced ? 'low' : settings.animationIntensity;
  return { reduced, disabled: settings.disableAnimations, continuous: !reduced && !settings.disableAnimations, preset: ANIMATION_PRESETS[intensity] };
}

/** response 对应自然周期；采样阻尼振子，不把 spring 参数误当作 cubic-bezier。 */
export function springProgress(seconds: number, response: number, damping: number): number {
  if (seconds <= 0) return 0;
  const omega = 2 * Math.PI / response;
  const decay = Math.exp(-damping * omega * seconds);
  const frequency = omega * Math.sqrt(1 - damping * damping);
  return 1 - decay * (Math.cos(frequency * seconds) + damping * omega / frequency * Math.sin(frequency * seconds));
}

export function magneticOffset(dx: number, dy: number): number {
  const distance = Math.hypot(dx,dy);
  if (!Number.isFinite(distance) || distance >= 80 || distance <= 1) return 0;
  return Math.max(-8,Math.min(8,dx * (1-distance/80)*.15));
}

function keyframes(duration: number, response: number, damping: number, frame: (progress: number) => Keyframe): Keyframe[] {
  const count = Math.max(2,Math.ceil(duration * 60));
  return Array.from({length:count+1},(_,index)=>({ ...frame(index===count?1:springProgress(index/count*duration,response,damping)), offset:index/count }));
}

export class IslandMotion {
  private size?: Animation;
  private jelly?: Animation;
  private magnet?: Animation;
  private settleTimer?: ReturnType<typeof setTimeout>;
  private lastSize = '';
  private magneticTarget = 0;
  private expanded = false;
  private policy: ReturnType<typeof motionPolicy>;
  constructor(private readonly shell: HTMLElement, settings: IslandSettings, systemReduced: boolean) {
    this.policy = motionPolicy(settings,systemReduced);
  }
  configure(settings: IslandSettings, systemReduced: boolean, expanded: boolean): void {
    this.expanded = expanded;
    this.policy = motionPolicy(settings,systemReduced);
    const {preset,disabled,continuous}=this.policy;
    this.shell.style.setProperty('--content-fade',`${disabled?0:preset.fade}s`);
    this.shell.style.setProperty('--content-delay',`${disabled?0:preset.start+preset.reveal}s`);
    if (!continuous || expanded) this.resetHover();
    if (disabled) { this.size?.cancel(); this.size=undefined; }
  }
  resize(previous: DOMRect, width:number, height:number, expanded:boolean):void {
    const identity=`${width}:${height}:${expanded}`;
    if(identity===this.lastSize)return;
    const first=this.lastSize==='';this.lastSize=identity;
    this.size?.cancel();
    if(first||this.policy.disabled||previous.width===0)return;
    const {preset}=this.policy;
    const [response,damping]=expanded?preset.expand:preset.collapse;
    const duration=Math.max(response,preset.finish);
    this.size=this.shell.animate(keyframes(duration,response,damping,progress=>({
      width:`${previous.width+(width-previous.width)*progress}px`,
      height:`${previous.height+(height-previous.height)*progress}px`,
      borderBottomLeftRadius:`${(expanded?17:22)+(expanded?5:-5)*progress}px`,
      borderBottomRightRadius:`${(expanded?17:22)+(expanded?5:-5)*progress}px`,
    })),{duration:duration*1000,delay:expanded?preset.start*1000:0,fill:'backwards',easing:'linear'});
  }
  enter(intensity:JellyIntensity,fromBelow:boolean):void {
    if(!this.policy.continuous||this.expanded||!fromBelow)return;
    this.resetHover();
    const scale=JELLY_PRESETS[intensity];
    this.jelly=this.shell.animate(keyframes(.5,.5,.3,p=>({transform:`scale(${1+(scale.xPop-1)*p},${1+(scale.yPop-1)*p})`})),{duration:500,fill:'forwards'});
    this.settleTimer=setTimeout(()=>{
      const matrix=new DOMMatrixReadOnly(getComputedStyle(this.shell).transform);
      this.jelly?.cancel();
      this.jelly=this.shell.animate(keyframes(.45,.45,.4,p=>({transform:`scale(${matrix.a+(scale.xSettle-matrix.a)*p},${matrix.d+(scale.ySettle-matrix.d)*p})`})),{duration:450,fill:'forwards'});
    },150);
  }
  pointer(x:number,y:number,collapsedHeight:number):void {
    if(!this.policy.continuous||this.expanded)return;
    const bounds=this.shell.getBoundingClientRect();
    const offset=magneticOffset(x-(bounds.left+bounds.width/2),y-(bounds.top+collapsedHeight/2));
    if(Math.abs(offset-this.magneticTarget)<.5&&offset!==0)return;
    if(offset===0&&this.magneticTarget===0)return;
    const body=this.shell.querySelector<HTMLElement>('.collapsed-body');
    if(!body)return;
    const current=new DOMMatrixReadOnly(getComputedStyle(body).transform).m41;
    this.magnet?.cancel();this.magneticTarget=offset;
    body.style.transform=`translateX(${offset}px)`;
    this.magnet=body.animate(keyframes(offset===0?.4:.3,offset===0?.4:.3,offset===0?.65:.7,p=>({transform:`translateX(${current+(offset-current)*p}px)`})),{duration:offset===0?400:300});
  }
  resetHover():void {
    if(this.settleTimer)clearTimeout(this.settleTimer);
    this.jelly?.cancel();this.magnet?.cancel();this.magneticTarget=0;
    const body=this.shell.querySelector<HTMLElement>('.collapsed-body');if(body)body.style.transform='';
  }
  destroy():void {this.resetHover();this.size?.cancel();}
}
