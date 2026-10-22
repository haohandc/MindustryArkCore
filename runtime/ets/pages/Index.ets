import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { applyImmersive, PanelHost, PanelSpec, readWindowPrefsSync, WindowPrefs } from 'core_internal';
import { abilityBridge } from '../gameability/AbilityBridge';
import { ImeBridge, ImeRect, ImeSnapshot, IME_FIELD_MARGIN_VP } from '../gameability/ImeBridge';

const DOMAIN = 0x0000;
const TAG = 'GamePage';

/** 输入框出现后 delay 再要焦点。太早要，它还没被布局出来，requestFocus 会落空。 */
const IME_FOCUS_DELAY_MS: number = 60;

/**
 * 把焦点要回来的重试时刻（毫秒）。一次不够 —— 挂载、surface 重建、
 * 输入框上树都可能把焦点挪走。
 */
const FOCUS_RETRY_MS: number[] = [0, 120, 400, 900];

/**
 * 游戏页。四层叠在一起，谁需要谁在上面：
 *
 *   Stack
 *     ├── XComponent       游戏画面。SDL 由它挂载，main() 由此被执行
 *     ├── 进度文字           JVM 起来之前显示
 *     ├── 输入法输入框      全透明，只为承接系统 IME
 *     └── PanelHost         启动失败时盖在最上面
 *
 * XComponent 一旦挂载就不能摘 —— 摘掉会拆掉 surface，游戏侧不会重建。
 *    所以失败时不是卸载它，而是在上面盖一层面板。
 */
@Entry
@Component
struct Index {
  @StorageLink('lp.panel') panel: PanelSpec | null = null;
  @StorageLink('lp.showProgress') showProgress: boolean = true;
  @StorageLink('lp.stageText') stageText: string = '';

  /* 输入法状态。由 ImeBridge 的轮询更新。 */
  @State imeShown: boolean = false;
  @State imeX: number = 0;
  @State imeY: number = 0;
  @State imeW: number = 0;
  @State imeH: number = 0;

  private ime: ImeBridge = new ImeBridge();

  aboutToAppear(): void {
    this.ime.start((snap: ImeSnapshot) => {
      this.applyIme(snap);
    });

    /* 沉浸在这里再摆一次。Ability 里那次用的是 `getMainWindowSync()`，取到的是
     *    窗口阶段刚建出来的那一个；页面起来之后真正承载画面的是「最后一个窗口」。
     *    所以这里用 `getLastWindow(ctx)`。XComponent 挂载会再动一次窗口，
     *    因此 Ability 里 loadContent 之后那次补摆也要保留。 */
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const prefs: WindowPrefs = readWindowPrefsSync(ctx);
      applyImmersive(ctx, prefs.gameImmersive).then(() => {
        hilog.info(DOMAIN, TAG, 'immersive: applied from the page (game=%{public}s)',
          prefs.gameImmersive ? 'on' : 'off');
      }).catch((e: Error) => {
        hilog.warn(DOMAIN, TAG, 'immersive: page-level apply failed: %{public}s', e.message);
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'immersive: could not reach the context');
    }
  }

  aboutToDisappear(): void {
    this.ime.stop();
  }

  /**
   * 把焦点要回 XComponent。只有获焦的组件才走 native 的按键回调。
   * `defaultFocus(true)` 只在页面首次显示时生效一次；IME 输入框一获焦，
   *    焦点就再也没回来过 —— 表现是「打过一次字之后，按键全部失灵」。
   */
  private claimGameFocus(): void {
    for (let i = 0; i < FOCUS_RETRY_MS.length; i++) {
      setTimeout(() => {
        if (this.panel !== null || this.imeShown) {
          return;
        }
        try {
          this.getUIContext().getFocusController().requestFocus('SDL_XComponent');
        } catch (e) {
          hilog.debug(DOMAIN, TAG, 'focus: SDL_XComponent not focusable yet');
        }
      }, FOCUS_RETRY_MS[i]);
    }
  }

  /**
   * 系统返回键 / 侧滑。永远返回 `true`，交给系统处理就等于退出应用。
   * 只在键盘弹着时补一个 ESC：那时输入框拿着焦点，按键到不了 XComponent。
   *    键盘没弹时按键本身已经到了游戏，再补一个就是两个 ESC。
   */
  onBackPress(): boolean {
    if (this.ime.isShown()) {
      this.ime.sendEscape();
      this.ime.markUserDismissed();
      this.imeShown = false;
      this.claimGameFocus();
    }
    return true;
  }

  /** 把桥给的像素矩形换算成 vp 并落到 @State。 */
  private applyIme(snap: ImeSnapshot): void {
    /* 只在状态真的变了才写 @State，避免每 200ms 触发一次无意义的重绘。 */
    if (this.imeShown !== snap.shown) {
      this.imeShown = snap.shown;
      /* 输入框消失后焦点不会自动回到 XComponent，不补这一步就是
       * 「打过一次字，之后按键全部失灵」。 */
      if (!snap.shown) {
        this.claimGameFocus();
      }
    }

    if (!snap.shown) {
      return;
    }

    const ui = this.getUIContext();
    const r: ImeRect = snap.rect;
    const x: number = ui.px2vp(r.x);
    const y: number = ui.px2vp(r.y);
    const w: number = ui.px2vp(r.w);
    const h: number = ui.px2vp(r.h);
    if (x === this.imeX && y === this.imeY && w === this.imeW && h === this.imeH) {
      return;
    }
    this.imeX = x;
    this.imeY = y;
    this.imeW = w;
    this.imeH = h;

    /* 刚显示时才要焦点 —— 已经有焦点时再要，会把已经弹出来的键盘推回去。
     * 目标节点可能还没上树（它是上一帧刚新建的），要不到焦点抛 150003，
     * 下一轮轮询会再试一次，这里不重试也不报错。 */
    setTimeout(() => {
      if (!this.imeShown) {
        return;
      }
      try {
        ui.getFocusController().requestFocus('ime_ui_field');
      } catch (e) {
        hilog.debug(DOMAIN, TAG, 'the IME field is not focusable yet');
      }
    }, IME_FOCUS_DELAY_MS);
  }

  build() {
    Stack() {
      XComponent({
        id: 'SDL_XComponent',
        type: XComponentType.SURFACE,
        libraryname: 'SDL3',
      })
        .id('SDL_XComponent')
        .focusable(true)
        .defaultFocus(true)
        .width('100%')
        .height('100%')
        .onAppear(() => {
          hilog.info(DOMAIN, TAG, 'XComponent appeared -- SDL is taking over');
          this.claimGameFocus();
        })
        .onDestroy(() => {
          hilog.warn(DOMAIN, TAG, 'XComponent destroyed');
        })
        /* 返回 false = 不消费，让 ArkUI 自己的处理和 native 回调各走各的。
         * 它拦不住系统把 ESC 当返回键，那条路是系统级的，由 `onBackPress` 管。 */
        .onKeyPreIme((_e: KeyEvent) => {
          return false;
        })

      /* 进度文字。游戏接管画面后由 GameAbility 置 false。 */
      if (this.showProgress && this.panel === null) {
        Column() {
          LoadingProgress()
            .width(48)
            .height(48)
            .color('#FFFFFF')
            .margin({ bottom: 18 })

          Text(this.stageText)
            .fontSize(15)
            .fontColor('#FFFFFF')
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor('#000000')
      }

      /* 输入法输入框。全透明 —— 玩家看到的是游戏自己画的框，这个大可放在
       * 游戏框上面，只为把系统 IME 接出来。
       * 高度故意比游戏框高 IME_FIELD_MARGIN_VP：键盘避让按这个高度推整页，
       *    齐平的话推上去的量会少一截，被弹出来的键盘盖住。 */
      if (this.imeShown && this.panel === null) {
        TextInput()
          .id('ime_ui_field')
          .position({ x: this.imeX, y: this.imeY })
          .width(this.imeW)
          .height(this.imeH + IME_FIELD_MARGIN_VP)
          .opacity(0)
          .onChange((value: string) => {
            this.ime.sendDelta(value);
          })
          .onSubmit(() => {
            this.ime.markUserDismissed();
            this.imeShown = false;
          })
          .onBlur(() => {
            this.ime.markUserDismissed();
            this.imeShown = false;
          })
      }

      /* 失败面板。盖在游戏画面之上，XComponent 保持挂载。 */
      if (this.panel !== null) {
        PanelHost({
          spec: this.panel,
          onAction: (id: string) => {
            hilog.info(DOMAIN, TAG, 'panel action: %{public}s', id);
            abilityBridge.dismissPanel();
          },
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
  }
}
