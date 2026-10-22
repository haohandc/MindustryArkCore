/**
 * ArkTS 与 native 之间的数据契约。
 * 字段名逐个对应 native 侧 setLaunchPlan() / getLaunchResult() 读写的属性名。
 * 名字写错不会报错 —— native 那边取不到就当成「没给」走缺省，症状是
 *    「明明传了却不生效」。改任何字段名都必须两边一起改。
 */

/**
 * 启动计划里要传给 native 的输入部分。
 * 由 entry 组装，经 want.parameters 交给 runtime 的 GameAbility，
 * 再经 setLaunchPlan() 交给 libmain.so。
 */
export interface LaunchPlan {
  /** 玩家导入的游戏 jar 绝对路径。空串 = 没有游戏可启动，native 会拒绝起 JVM。 */
  gameJar: string;

  /** 玩家选定的 mods 目录。空串 = 用 <userHome>/.local/share/Mindustry/mods。 */
  modsDir: string;

  /**
   * 本次的 -Duser.home。
   * 不隔离 = 数据根本身；隔离 = <数据根>/instances/<键>/sets/default。
   * 唯一必填字段：没有它 native 连沙箱 JDK 都装配不起来。
   */
  userHome: string;

  /** 游戏语言，空串 = 不设。两段值，例如 zh / CN。 */
  localeLang: string;
  localeCountry: string;

  /**
   * true = 移动端操作方案。
   * Mindustry 用 Vars.mobile 一个 bit 决定整个输入层与 UI，且该值必须在
   * Vars.init() 之前定好 —— 所以只能启动前传进去，游戏内改不了。
   */
  mobile: boolean;

  /**
   * true = 可执行内存可用（checkExecEnv() 返回 42）。
   * false 时 native 仍会起 JVM 但强制 -Xint，游戏会极慢；真正的拒绝启动在 ArkTS 侧做。
   */
  execMemOk: boolean;

  /** 开发开关，正常启动全 false。 */
  devNogame: boolean;
  devNohandlers: boolean;
  devMinimal: boolean;
  devNoexec: boolean;

  /** 追加到 JVM 选项表末尾的字符串，每条最长 255 字节。 */
  extraOpts: string[];
}

/** native 回报的启动进度。数值与 globals.h 的 PLAN_STAGE_* 逐项对应。 */
export enum LaunchStage {
  /** 还没开始，或卡死在 JNI_CreateJavaVM（那是不留任何证据的唯一一种失败）。 */
  None = 0,
  /** JNI_CreateJavaVM 已返回成功。 */
  JvmCreated = 1,
  /** 游戏入口方法已调起 —— 这个 jar 确实是个能跑的游戏。 */
  GameEntered = 2,
  /** 启动失败，看 exitCode。 */
  Failed = 3,
}

/** getLaunchResult() 的返回形状。 */
export interface LaunchResult {
  /** LaunchStage 的数值。 */
  stage: number;
  /** 进程退出码，见 ExitCode。 */
  exitCode: number;
  /** 1 = 结果已出来，exitCode 有效。处理完必须调 ackExit()。 */
  finished: number;
  /** 1 = 计划已就绪，可以启动。 */
  valid: number;
}

/**
 * 退出码。native 侧的 start_jvm() 与 main() 共用这张表。
 * 这是给界面选提示文案用的，不要拿它做流程判断 —— 流程只看 stage。
 */
export enum ExitCode {
  Ok = 0,
  AnchorNotLoaded = 1,
  NoCreateJavaVMFn = 2,
  PatchJarNotShipped = 3,
  PatchJarUnreadable = 4,
  NoGameJar = 5,
  JvmCreationFailed = 6,
  NoSandboxPaths = 7,
  NoLaunchPlan = 8,
  MainClassMissing = 9,
  NoMainMethod = 10,
  ArgvAllocationFailed = 11,
  GameThrewOnStart = 12,
}

/** 一份字段全满、但什么也不做的计划。调用方覆盖需要的字段即可。 */
export function createEmptyLaunchPlan(): LaunchPlan {
  const plan: LaunchPlan = {
    gameJar: '',
    modsDir: '',
    userHome: '',
    localeLang: '',
    localeCountry: '',
    mobile: true,
    execMemOk: false,
    devNogame: false,
    devNohandlers: false,
    devMinimal: false,
    devNoexec: false,
    extraOpts: [],
  };
  return plan;
}
