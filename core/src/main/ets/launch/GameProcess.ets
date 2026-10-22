import { appManager, common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * 「游戏那个进程现在在不在跑」。
 * 干什么用：删游戏包之前必须先问一句。游戏跑在 `:game` 进程里，
 *    JVM 用 `plan.gameJar` 的绝对路径当 classpath 的一部分，而 Mindustry
 *    是重度延迟加载的 —— 进一个新界面就按需打开这个 jar 读一批类。包被挪走之后
 *    那一刻就打不开了，游戏崩在用户面前。
 * 不用申请任何权限。 SDK（`@ohos.app.ability.appManager.d.ts:273-289`）原文：
 *    「Starting from API version 11, this API is used only to obtain the process
 *    information of the caller. No permission is required.」——
 *    `GET_RUNNING_INFO` 只对 API 9–10 是必需的。我们基线是 `6.1.1(24)`。
 * 手机上这个判断恒为 false：`abilities[].process` 只有平板与 2in1 生效，
 *    手机上 GameAbility 与 EntryAbility 在同一个进程里，没有 `:game` 这个名字。
 *    那边游戏在跑时启动器根本不在前台，够不着这个按钮，所以不影响结论。
 * 查不出来（抛异常）时当作在跑：宁可多问一句，也别让玩家删掉正在用的包。
 */

const DOMAIN = 0x0000;
const TAG = 'GameProcess';

/** 游戏那个进程的后缀。与 `runtime/module.json5` 里 `abilities[].process` 的后缀一致。 */
const GAME_PROCESS_SUFFIX: string = ':game';

/** 现在的状态。 */
export interface GameProcessState {
  /** 游戏进程在不在。查不出来时也是 true —— 见文件头。 */
  running: boolean;
  /** 跑的是不是查不出来。true 时 `running` 只是保守值，不能据此比对包名。 */
  unknown: boolean;
}

/**
 * 游戏进程在不在跑。
 * 异步、只读，几毫秒量级。只在按下删除那一刻调用一次 ——
 * 不需要轮询，也不需要缓存：这个状态随时会变。
 */
export async function gameProcessState(): Promise<GameProcessState> {
  try {
    const list: appManager.ProcessInformation[] = await appManager.getRunningProcessInformation();
    for (let i = 0; i < list.length; i++) {
      if (list[i].processName.endsWith(GAME_PROCESS_SUFFIX)) {
        return { running: true, unknown: false };
      }
    }
    return { running: false, unknown: false };
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'could not read the running processes: %{public}s', JSON.stringify(e));
    return { running: true, unknown: true };
  }
}

/**
 * 这个游戏包现在能不能删。
 * 三条判据，顺序即优先级：
 *   ① 游戏进程不在 → 能删
 *   ② 游戏进程在、但跑的是另一个包 → 能删。JVM 只打开它自己那个 jar，
 *      删掉不相干的包不影响它
 *   ③ 说不清跑的是哪个（查不出来、或者 `jarName` 是空串）→ 不能删
 *
 * 第 ③ 条不猜。`LaunchRecord.jarName` 只在「这一次启动有记录」时有值；
 *    记录被清过、或者读 preferences 失败，它都是空串。那种情况下按「可能是在跑
 *    这个包」处理，提示玩家先退出游戏 —— 比删下去崩在他面前好。
 * @param playingJar 正在跑的那个包的文件名。空串 = 不知道。
 */
export function canDeleteJar(state: GameProcessState, playingJar: string, jar: string): boolean {
  if (!state.running) {
    return true;
  }
  if (state.unknown || playingJar === '') {
    return false;
  }
  return playingJar !== jar;
}
