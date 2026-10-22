import { AbilityConstant, UIAbility, Want, abilityAccessCtrl } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { i18n } from '@kit.LocalizationKit';
import { inputMethod } from '@kit.IMEKit';
import pointer from '@ohos.multimodalInput.pointer';

import sdl from 'libSDL3.so';
import launchNative from 'libmain.so';

import {
  applyImmersiveToWindow,
  applyStoredUiLanguage,
  enableSandboxLogs,
  isDevUnlocked,
  createEmptyLaunchPlan,
  DEFAULT_IMMERSIVE_GAME,
  GameVersion,
  LaunchPlan,
  LaunchRecord,
  LaunchStage,
  markAttemptFinished,
  PanelSpec,
  PanelStyle,
  panelForLaunchFailure,
  readGameVersion,
  readLaunchRecordSync,
  readPanelStyle,
  readWindowPrefsSync,
  resolveOwnString,
  versionDisplayText,
  WindowPrefs,
} from 'core_internal';
import { abilityBridge } from './AbilityBridge';

const DOMAIN = 0x0000;
const TAG = 'GameAbility';

/** want.parameters 里放启动计划的那把键。entry 与这里必须一致。 */
export const WANT_LAUNCH_PLAN: string = 'launchPlanJson';

/** 轮询周期。250ms 足够跟上「JVM 起来 → 游戏起来」这两次跳变。 */
const POLL_MS: number = 250;

/** 读不出游戏版本时用的窗口名。 */
const DEFAULT_WINDOW_NAME: string = 'Mindustry';

/**
 * 页面装好之后再过多久补摆一次窗口。
 * 那一拍是给 XComponent 挂载、SDL 建 surface 留的。太短会赶在 surface 之前，
 * 太长会让玩家看到状态栏在那里杵一会儿。400ms 落在 SDL 起 native 线程之后。
 */
const IMMERSIVE_RETRY_MS: number = 400;

/**
 * 进度文字的资源，下标即 `LaunchStage`。
 * 这里存 `Resource`，不存取好的 `string`。
 *    进度文字经 `AppStorage` 的 `lp.stageText` 传给页面，而那个键的类型是
 *    `string`（`pages/Index.ets` 的 `@StorageLink`）—— 所以要用的时候必须
 *    先解析。放 `$r` 在这里、用的地方再解析，语言就不会在本模块装配时被定格。
 * 页面那一侧拿到的是已经解析好的 `string`，因为 `Text()` 收的是
 *    值而不是引用，`AppStorage` 里也不能存会变的东西。
 */
const STAGE_TEXT: Resource[] = [
  $r('app.string.stage_jvm_starting'),
  $r('app.string.stage_jvm_ready'),
  $r('app.string.stage_game_entered'),
  $r('app.string.stage_failed'),
];

export default class GameAbility extends UIAbility {
  private timerId: number = -1;
  private plan: LaunchPlan = createEmptyLaunchPlan();
  private lastStage: number = -1;
  private handled: boolean = false;
  /** labs 里选的弹窗画法。读不到就是 Normal。 */
  private panelStyle: PanelStyle = PanelStyle.Normal;
  /**
   * 这次 onCreate 拿到的不是一个启动请求。
   * 从最近任务列表点回来时，系统会重建 GameAbility 而不是恢复它，新实例的 want 里
   * 没有 launchPlanJson。那条路径不该起游戏 —— 没有游戏包、没有 user.home，
   * native 只会以退出码 5 拒绝。所以当场收摊，让玩家回到启动器。
   */
  private aborting: boolean = false;
  /** 游戏窗口。标题要等 loadContent 之后才设得上。 */
  private win: window.Window | null = null;
  /** 这次要显示的窗口名。版本还没读出来时是缺省名。 */
  private windowName: string = DEFAULT_WINDOW_NAME;
  /** 页面已经 loadContent 过。`setWindowTitle` 在那之前调不生效。 */
  private contentReady: boolean = false;
  /** 这次要摆成的沉浸状态。窗口可能要摆不止一次，值先记下来。 */
  private immersiveWanted: boolean = DEFAULT_IMMERSIVE_GAME;

  /**
   * 取一条进度文字，按当前语言解析成 `string`。
   * `AppStorage` 的那个键是 `string`，页面用 `@StorageLink` 接 —— 存不了
   *    `Resource`（它在页面里不会被解析，`Text` 会画成 `[object Object]`）。
   *    所以在这里解析，页面只管显示。
   * 走 core 的 `resolveOwnString`，不要直接调 `getStringSync`：失败时它返回
   *    key 名而不是空串 —— 界面空着看不出是没字还是没解析出来。
   */
  private stageText(index: number): string {
    const at: number = (index >= 0 && index < STAGE_TEXT.length) ? index : 0;
    return resolveOwnString(this.context, STAGE_TEXT[at], 'stage_text');
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    /* 游戏 HAP 跑在 `:game` 进程里，进程第一次起来时资源已经按应用偏好语言取过一遍 ——
     * 这里再设一次是幂等的，代价只有一次 preferences 读；好处是「直接从最近任务回到
     * 游戏」那条路径上，进程内的进度文案也不会是旧语言。 */
    applyStoredUiLanguage(this.context);

    /* 开发者模式解锁过就把本进程的日志也落到沙箱。
     * `setOutputType` 是进程级设置，entry 那边开的只管启动器进程 ——
     *    SDL、JVM、native 的日志全部由 `:game` 进程打，不在这里开就一行都存不下来。
     * 必须放在 onCreate 最早处：想在「游戏启动那一段」留下记录，
     *    就得在 native 动起来之前打开。
     * 解锁状态走应用级 preferences，跨 HAP 读得到（`isDevUnlocked`）。
     * 接口是 API 26 的，低版本设备上 `enableSandboxLogs` 返回 false，不影响启动。 */
    if (isDevUnlocked(this.context)) {
      enableSandboxLogs();
    }

    hilog.info(DOMAIN, TAG, 'onCreate');

    /* ① 从 want 解出启动计划。entry 用一个 JSON 字符串传，
     *    避开 want.parameters 对数组类型的支持问题。 */
    this.plan = this.parsePlan(want);

    /* 没有游戏包就说明这次不是启动请求（最典型：从最近任务列表点回来）。
     * 判据必须是 gameJar 而不是 launchNative 的 valid —— setLaunchPlan() 一旦被调，
     *    native 就把 valid 置 1，哪怕传进去的是字段全空的计划。 */
    if (this.plan.gameJar === '') {
      hilog.info(DOMAIN, TAG, 'no game jar in the plan -- this is not a launch request; terminating');
      this.aborting = true;
      this.context.terminateSelf().catch((e: Error) => {
        hilog.warn(DOMAIN, TAG, 'terminateSelf failed: %{public}s', e.message);
      });
      return;
    }

    /* ①-补 窗口名 = 游戏版本。异步读 jar，读完再换名字；读不出来就停在缺省名。 */
    this.resolveWindowName();

    /* ② 交给 native。必须在 XComponent 挂载之前 —— main() 跑在 SDL 新起的线程上，
     *    而线程创建本身就是一次同步：setLaunchPlan 返回之后的写，main() 一定看得见。 */
    try {
      launchNative.setLaunchPlan(this.plan);
      hilog.info(DOMAIN, TAG, 'launch plan handed to native');
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'setLaunchPlan failed: %{public}s', JSON.stringify(e));
    }

    /* ③ 把 ArkTS 对象交给 SDL。参数个数固定为 5，少一个它 exit(1)。
     *    顺序照抄 SDL_openharmony.c 里 argv[0..4] 的读取顺序。 */
    try {
      sdl.provideArkTSObjects(this,
                              abilityAccessCtrl.createAtManager(),
                              i18n.System,
                              pointer.setPointerVisibleSync,
                              inputMethod.getController());
      hilog.info(DOMAIN, TAG, 'ArkTS objects provided to SDL');
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'provideArkTSObjects failed: %{public}s', JSON.stringify(e));
    }

    /* ④ 初值先摆好，页面一起来就能读到。 */
    AppStorage.setOrCreate('lp.stageText', this.stageText(0));
    AppStorage.setOrCreate('lp.showGame', true);
    AppStorage.setOrCreate('lp.showProgress', true);
    AppStorage.setOrCreate('lp.panel', null as PanelSpec | null);

    /* ⑤ 把「玩家点掉了面板」这个动作接上。页面拿不到 Ability 实例。 */
    abilityBridge.registerDismiss(() => {
      this.dismissPanel();
    });

    /* ⑥ 读 labs 里的弹窗画法。异步，读不到就用 Normal —— 样式偏好坏了不该影响启动。 */
    readPanelStyle(this.context).then((style: PanelStyle) => {
      this.panelStyle = style;
    }).catch(() => {
      this.panelStyle = PanelStyle.Normal;
    });

    this.startPolling();
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, 'onWindowStageCreate');

    /* onCreate 已经判定这不是启动请求。不要 loadContent —— 页面一挂，XComponent
     * 就会把 SDL 拉起来，main() 紧跟着执行。 */
    if (this.aborting) {
      hilog.info(DOMAIN, TAG, 'aborting: not loading the game page');
      this.context.terminateSelf().catch((e: Error) => {
        hilog.warn(DOMAIN, TAG, 'terminateSelf failed: %{public}s', e.message);
      });
      return;
    }

    /* 窗口先摆，页面后装。反过来的话第一帧按系统默认画一次，开着沉浸时会看到
     * 画面往下缩一下再铺开。
     * 沉浸与否由设置页那个「游戏沉浸模式」决定（默认开）。读偏好用同步接口 ——
     * 这里等 Promise 同样会让第一帧先出来。 */
    const prefs: WindowPrefs = readWindowPrefsSync(this.context);
    this.immersiveWanted = prefs.gameImmersive;

    let win: window.Window | null = null;
    try {
      win = windowStage.getMainWindowSync();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'getMainWindowSync failed: %{public}s', JSON.stringify(e));
    }

    this.win = win;
    if (win === null) {
      this.loadGamePage(windowStage);
      return;
    }

    /* applyImmersiveToWindow 自己吞掉错误，这里的 catch 只是兜底 ——
     * 窗口摆不成也要把页面装上，否则 XComponent 不挂载、native 永远等不到启动。 */
    applyImmersiveToWindow(win, prefs.gameImmersive).then(() => {
      this.loadGamePage(windowStage);
    }).catch(() => {
      this.loadGamePage(windowStage);
    });
  }

  private loadGamePage(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      this.contentReady = true;
      this.applyWindowTitle();

      /* 页面装好了再摆一次窗口。
       * `onWindowStageCreate` 里那一次是在窗口刚建出来时调的，那时它还没进入全屏 ——
       * 而 `setWindowSystemBarEnable` 在非全屏 / 非最大化状态下不生效（官方接口注释
       * 原文：the setting does not take effect when the main window is in non-full-screen
       * or non-maximized mode）。启动器那个窗口是点图标起来的，建出来就是全屏，所以
       * 那里一次就够；游戏窗口是 startAbility 拉起来的，差这一拍。
       * 再等一拍是因为 XComponent 挂载会把 surface 重建一次，SDL 侧拿到新 surface
       * 之后可能自己动一遍窗口属性。 */
      this.reapplyImmersive('after loadContent');
      setTimeout(() => {
        this.reapplyImmersive('after the surface is up');
      }, IMMERSIVE_RETRY_MS);
    });
  }

  /** 按记下来的偏好把窗口再摆一次。摆不成只记日志 —— 沉浸是观感，不该挡住游戏。 */
  private reapplyImmersive(why: string): void {
    if (this.win === null) {
      return;
    }
    applyImmersiveToWindow(this.win, this.immersiveWanted).then(() => {
      hilog.info(DOMAIN, TAG, 'immersive reapplied (%{public}s)', why);
    }).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, 'could not reapply immersive (%{public}s): %{public}s',
        why, e.message);
    });
  }

  onForeground(): void {
    /* 从后台回来时系统会把系统栏还回来。重新摆一次。 */
    this.reapplyImmersive('onForeground');
  }

  /* ---------------- 窗口名 ---------------- */

  /**
   * 窗口名 = 游戏版本。
   * 版本读的是 jar 根上的 `version.properties` —— 与版本隔离用的是同一个判据，
   *    所以两处显示永远不会对不上。
   * 落到两处，用途不同：
   *   `setMissionLabel` —— 最近任务里这张卡片的标题，API 9 起随时可调；
   *   `setWindowTitle`  —— 2in1 自由窗口标题栏上的字，API 15 起、必须 loadContent 之后。
   * 读不出来就用缺省名，不猜版本 —— 「Mindustry 160」猜错了比只写 Mindustry 更糟。
   */
  private resolveWindowName(): void {
    readGameVersion(this.context, this.plan.gameJar).then((v: GameVersion) => {
      /* 用给人看的形式（`v8 build160.5`），与界面上的副标题一致 ——
       * 同一个包在列表里和任务卡上写成两个样子，玩家会以为是两个版本。 */
      const text: string = versionDisplayText(v);
      const name: string = (text === '') ? DEFAULT_WINDOW_NAME : `${DEFAULT_WINDOW_NAME} ${text}`;
      hilog.info(DOMAIN, TAG, 'window name: %{public}s (from %{public}s)', name, v.source);
      this.applyWindowName(name);
    }).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, 'could not read the game version: %{public}s', e.message);
      this.applyWindowName(DEFAULT_WINDOW_NAME);
    });
  }

  private applyWindowName(name: string): void {
    this.windowName = name;
    try {
      this.context.setMissionLabel(name).catch((e: Error) => {
        hilog.warn(DOMAIN, TAG, 'setMissionLabel failed: %{public}s', e.message);
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'setMissionLabel threw: %{public}s', JSON.stringify(e));
    }
    this.applyWindowTitle();
  }

  /**
   * 2in1 自由窗口的标题。
   * 平板上不支持（抛 801），全屏沉浸时标题栏本来也看不见 —— 失败只记一条 info，
   *    不弹面板。名字是锦上添花，不该影响游戏能不能起来。
   */
  private applyWindowTitle(): void {
    if (this.win === null || !this.contentReady) {
      return;
    }
    try {
      this.win.setWindowTitle(this.windowName).catch((e: Error) => {
        hilog.info(DOMAIN, TAG, 'setWindowTitle not applied here: %{public}s', e.message);
      });
    } catch (e) {
      hilog.info(DOMAIN, TAG, 'setWindowTitle threw here: %{public}s', JSON.stringify(e));
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onDestroy');
    this.stopPolling();
    abilityBridge.unregister();
  }

  /* ---------------- 启动计划 ---------------- */

  private parsePlan(want: Want): LaunchPlan {
    const plan: LaunchPlan = createEmptyLaunchPlan();

    const params = want.parameters;
    if (params === undefined) {
      hilog.error(DOMAIN, TAG, 'want has no parameters at all');
      return plan;
    }

    const raw = params[WANT_LAUNCH_PLAN];
    if (typeof raw !== 'string' || raw === '') {
      hilog.error(DOMAIN, TAG, 'want has no %{public}s', WANT_LAUNCH_PLAN);
      return plan;
    }

    try {
      const parsed = JSON.parse(raw) as LaunchPlan;
      hilog.info(DOMAIN, TAG, 'plan parsed: jar=%{public}s home=%{public}s',
                 parsed.gameJar, parsed.userHome);
      return parsed;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'plan is not valid JSON: %{public}s', JSON.stringify(e));
      return plan;
    }
  }

  /* ---------------- 轮询 ---------------- */

  private startPolling(): void {
    this.timerId = setInterval(() => {
      this.pollOnce();
    }, POLL_MS);
  }

  private stopPolling(): void {
    if (this.timerId !== -1) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  private pollOnce(): void {
    /* 不要写成 `let r: LaunchResult = launchNative.getLaunchResult()`。
     *    native 的声明是 LaunchResultOutput，与 core 的 LaunchResult 结构相同但
     *    不同名，而 ArkTS 禁止结构类型（arkts-no-structural-typing）。
     *    所以这里只把需要的三个数字取出来，全程不碰那个对象类型。 */
    let stage: number = 0;
    let exitCode: number = 0;
    let finished: number = 0;

    try {
      const r = launchNative.getLaunchResult();
      stage = r.stage;
      exitCode = r.exitCode;
      finished = r.finished;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'getLaunchResult threw: %{public}s', JSON.stringify(e));
      return;
    }

    /* 进度文字只在阶段变化时更新，避免每 250ms 重设一次 @StorageLink。 */
    if (stage !== this.lastStage) {
      this.lastStage = stage;
      AppStorage.setOrCreate('lp.stageText', this.stageText(stage));
    }

    if (stage === LaunchStage.GameEntered) {
      /* 游戏已经接管画面，进度文字该退了。 */
      AppStorage.setOrCreate('lp.showProgress', false);
    }

    /* finished === 0 表示 native 还在跑，继续等。 */
    if (finished !== 1) {
      return;
    }

    /* 只处理一次。之后 native 等着 ack，别重复弹面板。 */
    if (this.handled) {
      return;
    }
    this.handled = true;
    this.stopPolling();

    this.finishWithResult(exitCode, stage);
  }

  private finishWithResult(exitCode: number, stage: number): void {
    hilog.info(DOMAIN, TAG, 'finished: exit=%{public}d stage=%{public}d', exitCode, stage);

    /* 先读一次这次尝试的痕迹 —— 记时长要用它的开始时刻。
     * 必须在 markAttemptFinished 之前读：那一步会把结论改写掉。 */
    const record: LaunchRecord = readLaunchRecordSync(this.context);

    /* 这一局跑了多久。只在游戏真的接管过画面时算（GameEntered 及之后）——
     * JVM 没起来就退出的那种，时长没有意义，也不该算进总时长。
     * attemptAt 为 0 表示没有开始记录（记录被清过），这时算出来的差值是个天文数字。 */
    const sessionMs: number =
      (stage >= LaunchStage.GameEntered && record.attemptAt > 0) ? Date.now() - record.attemptAt : 0;

    /* 记录这次的结果。正常与异常都记 —— 正常时它是一条时间戳，
     * 异常时它是下次启动能读到的那份证据。
     * 时长顺手交出去（`sessionMs`），由 entry 侧取走落账 —— 见
     *    `markAttemptFinished` 的说明。这里不碰实例层。 */
    markAttemptFinished(this.context, exitCode, sessionMs).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, 'markAttemptFinished failed: %{public}s', e.message);
    });

    if (exitCode === 0) {
      /* 正常退出：不打扰玩家，直接收摊。 */
      AppStorage.setOrCreate('lp.showProgress', false);
      this.terminateNow();
      return;
    }

    /* 失败：弹面板，等玩家点掉再退。native 那边正等着 ack，最多 30 秒。
     * 只传 exitCode —— 整个 r 传不进去，ArkTS 禁止结构类型。 */
    const spec: PanelSpec = panelForLaunchFailure(this.context, exitCode, this.plan.gameJar,
      this.panelStyle);
    AppStorage.setOrCreate('lp.panel', spec);
    AppStorage.setOrCreate('lp.showProgress', false);
  }

  /** 页面经 abilityBridge 调这个：玩家已经看完面板。 */
  dismissPanel(): void {
    AppStorage.setOrCreate('lp.panel', null as PanelSpec | null);
    this.terminateNow();
  }

  private terminateNow(): void {
    /* 顺序承重：先 ackExit 再 terminateSelf 亦可，但不能只做前者。
     *    只 ack 会让 native 立刻退出，那时 ability 还活着 —— 系统把这次退出记成
     *    "Cpp Crash"。所以两个都做，且先让框架知道我们也要走。 */
    this.context.terminateSelf().catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, 'terminateSelf failed: %{public}s', e.message);
    });
    try {
      launchNative.ackExit();
      hilog.info(DOMAIN, TAG, 'acked exit');
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'ackExit failed: %{public}s', JSON.stringify(e));
    }
  }
}
