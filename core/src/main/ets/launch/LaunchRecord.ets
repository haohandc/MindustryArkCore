import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { openAppPrefs, openAppPrefsSync } from '../utils/AppPrefs';

/**
 * 「上次启动发生了什么」的记录。丙方案的全部实现。
 * 它解决的是内存标志覆盖不到的那一半：GameAbility 跑在 :game 进程里，
 *    native 一旦卡死在 JNI_CreateJavaVM 或被信号打死，整个进程一起没了，
 *    连 ArkTS 都没机会说话。那一场的结论只能留到下次启动再说。
 * 用 preferences 而不是文件：这是状态，不是数据；系统负责原子性与清理。
 */

const DOMAIN = 0x0000;
const TAG = 'LaunchRecord';
const STORE = 'launch_record';

const KEY_PENDING = 'attempt_in_flight';
const KEY_ATTEMPT_AT = 'attempt_at';
const KEY_INSTANCE = 'instance_name';
const KEY_JAR_NAME = 'jar_name';
const KEY_LAST_EXIT_CODE = 'last_exit_code';
const KEY_LAST_EXIT_AT = 'last_exit_at';
const KEY_SESSION_MS = 'session_ms';
const KEY_SESSION_INSTANCE = 'session_instance';

/** 一次启动尝试的痕迹。 */
export interface LaunchRecord {
  /** 上次启动没有正常结束。true 时其余字段才有意义。 */
  interrupted: boolean;
  /** 那次尝试的开始时间（毫秒）。0 = 没有记录。 */
  attemptAt: number;
  /** 那次启动的实例名。空串 = 没有记录。 */
  instanceName: string;
  /**
   * 那次启动的游戏包文件名。
   * 存名字不存绝对路径：存储位置切到另一侧之后整棵目录都换了根，
   *    记下来的旧路径会指向一个不存在的地方，于是「上次那个包不见了」被误判成
   *    「包被删了」，自动进游戏永远不生效。
   */
  jarName: string;
  /** 最后一次记录的退出码。0 = 正常，非 0 = 对应 ExitCode。 */
  lastExitCode: number;
}

/**
 * 一局待记账的时长。runtime 写进记录，entry 取走。
 * 它不在 `LaunchRecord` 里 —— 那是「上次启动发生了什么」的只读快照，
 *    而这个东西取一次就该消失。放进接口里会诱使调用方直接读而不清，
 *    于是同一局被记两遍。唯一的读法是 `consumeSession`，它取走即清空。
 */
export interface PendingSession {
  /** 那一局用的实例名。空串 = 只加总时长（不计到某个实例上）。 */
  instance: string;
  /** 那一局跑了多久（毫秒）。恒为正。 */
  ms: number;
}

/**
 * 打开记录。用应用级 preferences —— 这份记录是跨 HAP 的：
 * entry 写「尝试开始」，runtime 的 GameAbility 写「结果」与退出码，entry 下次启动再读。
 * 用 UIAbilityContext 开的话两边是两个文件，结果永远是「上次没正常结束」。
 */
async function openStore(ctx: common.UIAbilityContext): Promise<preferences.Preferences | null> {
  return openAppPrefs(ctx, STORE);
}

/**
 * 拉起游戏之前调用。写一笔「我正在尝试」，并清掉上一次的结论。
 * 必须在 startAbility() 之前完成 —— 那之后 :game 进程随时可能启动并抢先写。
 */
export async function markAttemptStarted(ctx: common.UIAbilityContext,
                                         instanceName: string,
                                         jarName: string): Promise<void> {
  try {
    const store = await openStore(ctx);
    if (store === null) {
      return;
    }
    await store.put(KEY_PENDING, true);
    await store.put(KEY_ATTEMPT_AT, Date.now());
    await store.put(KEY_INSTANCE, instanceName);
    await store.put(KEY_JAR_NAME, jarName);
    await store.put(KEY_LAST_EXIT_CODE, 0);
    await store.put(KEY_LAST_EXIT_AT, 0);
    await store.flush();
    hilog.info(DOMAIN, TAG, 'attempt started: %{public}s / %{public}s', instanceName, jarName);
  } catch (e) {
    /* 记录不下来不该拦住启动 —— 最坏情况是失败时少了归因信息。 */
    hilog.warn(DOMAIN, TAG, 'could not record the attempt: %{public}s', JSON.stringify(e));
  }
}

/**
 * 处理完启动结果之后调用。正常与异常都调。
 * exitCode === 0 → 清掉尝试标记，只留一条「上次正常退出」的时间戳
 * exitCode !== 0 → 保留结论，下次启动时 entry 能读到
 *
 * @param sessionMs 这一局跑了多久（毫秒）。0 = 不记（JVM 没起来，或没有开始时刻）。
 * 时长只交出去，不在这里落账。 落账要改 `instance.json` 的 `playtimeMs`
 *    再加总时长，那套代码住在实例层（`Instance` / `InstanceOrder` / `StorageRoot`
 *    一千多行）。让它留在 entry 侧，runtime 就只需要交出一个数字 —— 这是
 *    「:game 进程里不出现实例管理代码」的全部实现。取走时用 `consumeSession`。
 */
export async function markAttemptFinished(ctx: common.UIAbilityContext,
                                          exitCode: number,
                                          sessionMs: number = 0): Promise<void> {
  try {
    const store = await openStore(ctx);
    if (store === null) {
      return;
    }
    /* 实例名从记录里抄一份，不额外传参 —— `markAttemptStarted` 一定写过它。
     * 在这里抄下来之后，即使下一次启动改掉了 `KEY_INSTANCE`，待记的这一笔
     * 也还是原来那个实例。 */
    const instanceName: string = await store.get(KEY_INSTANCE, '') as string;
    const valid: boolean = Number.isFinite(sessionMs) && sessionMs > 0;

    await store.put(KEY_PENDING, false);
    await store.put(KEY_LAST_EXIT_CODE, exitCode);
    await store.put(KEY_LAST_EXIT_AT, Date.now());
    await store.put(KEY_SESSION_MS, valid ? sessionMs : 0);
    await store.put(KEY_SESSION_INSTANCE, valid ? instanceName : '');
    await store.flush();
    hilog.info(DOMAIN, TAG, 'attempt finished: exit=%{public}d session=%{public}d',
      exitCode, valid ? sessionMs : 0);
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'could not record the result: %{public}s', JSON.stringify(e));
  }
}

/**
 * 取走待记账的那一局时长。取走即清空，同一局只能取到一次。
 * 读和清必须一次 flush 完成：分两次的话，调用方在中间崩掉就会重复记账。
 * 没有待记的东西时返回 `null`，不写盘。
 */
export async function consumeSession(ctx: common.UIAbilityContext): Promise<PendingSession | null> {
  try {
    const store = await openStore(ctx);
    if (store === null) {
      return null;
    }
    const ms: number = await store.get(KEY_SESSION_MS, 0) as number;
    if (!Number.isFinite(ms) || ms <= 0) {
      return null;
    }
    const instance: string = await store.get(KEY_SESSION_INSTANCE, '') as string;

    await store.put(KEY_SESSION_MS, 0);
    await store.put(KEY_SESSION_INSTANCE, '');
    await store.flush();

    hilog.info(DOMAIN, TAG, 'session handed over: %{public}d ms / %{public}s', ms, instance);
    return { instance: instance, ms: ms };
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'could not hand over the session: %{public}s', JSON.stringify(e));
    return null;
  }
}

/**
 * 读取上一次启动的痕迹。entry 在启动界面时调一次。
 * interrupted === true 表示「上次开了游戏但没等到结论」—— 进程死在半路。
 */
export async function readLaunchRecord(ctx: common.UIAbilityContext): Promise<LaunchRecord> {
  const record: LaunchRecord = {
    interrupted: false,
    attemptAt: 0,
    instanceName: '',
    jarName: '',
    lastExitCode: 0,
  };

  try {
    const store = await openStore(ctx);
    if (store === null) {
      return record;
    }
    record.interrupted = await store.get(KEY_PENDING, false) as boolean;
    record.attemptAt = await store.get(KEY_ATTEMPT_AT, 0) as number;
    record.instanceName = await store.get(KEY_INSTANCE, '') as string;
    record.jarName = await store.get(KEY_JAR_NAME, '') as string;
    record.lastExitCode = await store.get(KEY_LAST_EXIT_CODE, 0) as number;
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'could not read the record: %{public}s', JSON.stringify(e));
  }

  return record;
}

/**
 * 同步读。启动那一刻要立刻拿主意时用它 —— 自动进游戏的判据就走这条。
 * 与 `readLaunchRecord` 读的是同一份数据，只是不等 Promise。
 */
export function readLaunchRecordSync(ctx: common.UIAbilityContext): LaunchRecord {
  const record: LaunchRecord = {
    interrupted: false,
    attemptAt: 0,
    instanceName: '',
    jarName: '',
    lastExitCode: 0,
  };

  const store: preferences.Preferences | null = openAppPrefsSync(ctx, STORE);
  if (store === null) {
    return record;
  }

  try {
    record.interrupted = store.getSync(KEY_PENDING, false) as boolean;
    record.attemptAt = store.getSync(KEY_ATTEMPT_AT, 0) as number;
    record.instanceName = store.getSync(KEY_INSTANCE, '') as string;
    record.jarName = store.getSync(KEY_JAR_NAME, '') as string;
    record.lastExitCode = store.getSync(KEY_LAST_EXIT_CODE, 0) as number;
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'could not read the record (sync): %{public}s', JSON.stringify(e));
  }

  return record;
}

/** 玩家看过提示之后清掉痕迹，免得每次都弹。 */
export async function clearLaunchRecord(ctx: common.UIAbilityContext): Promise<void> {
  try {
    const store = await openStore(ctx);
    if (store === null) {
      return;
    }
    await store.put(KEY_PENDING, false);
    await store.flush();
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'could not clear the record: %{public}s', JSON.stringify(e));
  }
}
