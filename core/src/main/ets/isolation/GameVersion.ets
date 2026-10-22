import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { readJarTextEntry } from '../utils/JarEntry';

/**
 * 从一个游戏 jar 里认出它是哪一版。
 * 真相源是 jar 根上的 `version.properties`，不是 MANIFEST，也不是文件名。
 *    实测（Mindustry 160.5 / 160.7）：`META-INF/MANIFEST.MF` 里只有 `Main-Class`
 *    之类的启动信息，没有任何版本字段；版本在根上的 `version.properties`：
 *
 *      number=8
 *      build=160.5
 *      modifier=release
 *      type=official
 *
 *    游戏自己的 `mindustry/core/Version.class` 就是读这个文件的 —— 它把这几个字段
 *    拆成 `number` / `build` / `revision`（类里能看到 `\.`、`split`、`revision` 几个符号）。
 * 读不到就退回文件名（`Mindustry-160.5.jar` 里抠 `160.5`）。
 *    退回值可能比真版本粗（文件名不带版本时更糟），所以它的档位判据要跟着降级 ——
 *    见 `pickKey`。
 */

const DOMAIN = 0x0000;
const TAG = 'GameVersion';

/** 版本属性在 jar 里的位置。Mindustry 把它放在包的根上。 */
const VERSION_ENTRY = 'version.properties';

/** 一个游戏版本的三段。拿不到的段是空串。 */
export interface GameVersion {
  /** 大版本，例如 `8`。 */
  number: string;
  /** 完整构建号，例如 `160.5`。 */
  build: string;
  /** 构建号的小数部分，例如 `5`。没有小数时是空串。 */
  revision: string;
  /** 这个结果是从哪来的，只写日志与排查用。 */
  source: string;
}

function emptyVersion(source: string): GameVersion {
  const out: GameVersion = { number: '', build: '', revision: '', source: source };
  return out;
}

/**
 * 把版本拼回一行字，例如 `160.5`、`161`。
 * `build` 与 `revision` 在接口里是拆开的（`160` 与 `5`），
 *    直接拿 `build` 显示会得到 `160`，少掉小数那一段。
 * 各段都读不出来时返回空串 —— 调用方据此决定显示缺省名，而不是显示一个猜的值。
 */
export function versionText(v: GameVersion): string {
  if (v.build === '') {
    return v.number;
  }
  return (v.revision === '') ? v.build : `${v.build}.${v.revision}`;
}

/**
 * 显示用的完整版本：`v8 build160.5`。
 * 两个数说的事不一样：
 *   `number`（8）—— 大版本。存档兼容性、语言包、mod API 都按它分代。
 *   `build`（160.5）—— 具体构建号。玩家平时说的「160.5」就是它。
 *   只说构建号的话，看的人不知道这属于第几代；只说大版本又太粗。
 * 这个结果不能拿去做逻辑判断。 `isDowngrade` 是逐段 parseInt 比较的，
 *    传进来 `v8 build160.5` 会解析成 NaN，降级警告就静默失效了 ——
 *    那种比较用它下面的 `versionText`。
 * 也不能拿它当文件名（`prep` 的改名）。里面有空格。
 * 缺哪一段就省略哪一段：只读出大版本时是 `v8`，只读出构建号时是 `build160.5`。
 */
export function versionDisplayText(v: GameVersion): string {
  const parts: string[] = [];
  if (v.number !== '') {
    parts.push(`v${v.number}`);
  }
  const build: string = versionText(v);
  if (build !== '') {
    parts.push(`build${build}`);
  }
  return parts.join(' ');
}

/** 把 `160.5` 拆成 `160` 与 `5`。没有小数点时 revision 是空串。 */
function splitBuild(build: string, out: GameVersion): void {
  const dot: number = build.indexOf('.');
  if (dot === -1) {
    out.build = build;
    out.revision = '';
    return;
  }
  out.build = build.substring(0, dot);
  out.revision = build.substring(dot + 1);
}

/**
 * 解析 `version.properties` 那种 `key=value` 文本。
 * 值是 Java properties 格式：冒号与等号都可能被转义（`September 20, 2026 13\:57 PM`）。
 *    我们只取 `number` 与 `build` 两个纯数字字段，不受影响，但仍把反斜杠去掉。
 */
function parseProperties(text: string, out: GameVersion): void {
  const lines: string[] = text.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line: string = lines[i].trim();
    if (line === '' || line.startsWith('#')) {
      continue;
    }
    const eq: number = line.indexOf('=');
    if (eq === -1) {
      continue;
    }
    const key: string = line.substring(0, eq).trim();
    const value: string = line.substring(eq + 1).trim().replace(/\\/g, '');
    if (key === 'number') {
      out.number = value;
    } else if (key === 'build') {
      splitBuild(value, out);
    }
  }
}

/**
 * 从文件名里抠版本。
 * 认两种写法：`Mindustry-160.5.jar`、`Mindustry160.5.jar`。
 * 取最后一段形如 `数字.数字`（或单个数）的东西 —— 前面的 `Mindustry` 不含数字。
 */
function versionFromFileName(name: string): string {
  const base: string = name.toLowerCase().endsWith('.jar')
    ? name.substring(0, name.length - 4) : name;

  /* 从右往左找第一段「数字[.数字]」。 */
  let end: number = base.length;
  while (end > 0) {
    let start: number = end;
    while (start > 0) {
      const ch: string = base.charAt(start - 1);
      const isDigit: boolean = ch >= '0' && ch <= '9';
      if (!isDigit && ch !== '.') {
        break;
      }
      start--;
    }
    const piece: string = base.substring(start, end);
    /* 至少含一个数字才算数 —— 避免把结尾的点当成版本。 */
    if (piece !== '' && piece !== '.' && /\d/.test(piece)) {
      return piece.replace(/^\.+|\.+$/g, '');
    }
    /* 这一段全是分隔符，往前退一格继续找。 */
    end = start > 0 ? start - 1 : 0;
  }
  return '';
}

/**
 * 认出一个 jar 的版本。
 * @param jarPath 游戏包的绝对路径。
 * @return 认不出来时各段都是空串，`source` 说明原因。
 */
export async function readGameVersion(ctx: common.UIAbilityContext,
                                      jarPath: string): Promise<GameVersion> {
  if (jarPath === '') {
    return emptyVersion('no jar');
  }

  try {
    const text: string = await readJarTextEntry(ctx, jarPath, VERSION_ENTRY);
    if (text !== '') {
      const fromJar: GameVersion = emptyVersion('version.properties');
      parseProperties(text, fromJar);
      if (fromJar.number !== '' || fromJar.build !== '') {
        hilog.info(DOMAIN, TAG, 'version from %{public}s: number=%{public}s build=%{public}s',
          VERSION_ENTRY, fromJar.number, fromJar.build);
        return fromJar;
      }
      hilog.warn(DOMAIN, TAG, '%{public}s exists but has no number or build', VERSION_ENTRY);
    }
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'could not read the version properties: %{public}s',
      JSON.stringify(e));
  }

  /* 退回文件名。文件名里通常只有完整构建号，`number` 那段拿不到。 */
  const slash: number = jarPath.lastIndexOf('/');
  const name: string = (slash === -1) ? jarPath : jarPath.substring(slash + 1);
  const build: string = versionFromFileName(name);
  if (build === '') {
    hilog.warn(DOMAIN, TAG, 'cannot tell the version of %{public}s', name);
    return emptyVersion('unknown');
  }

  const fromName: GameVersion = emptyVersion('file name');
  splitBuild(build, fromName);
  hilog.info(DOMAIN, TAG, 'version from the file name: build=%{public}s', fromName.build);
  return fromName;
}
