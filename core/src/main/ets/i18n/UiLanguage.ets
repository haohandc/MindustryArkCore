import { application, common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { i18n } from '@kit.LocalizationKit';
import { resourceManager } from '@kit.LocalizationKit';
import { openAppPrefs, openAppPrefsSync } from '../utils/AppPrefs';

/**
 * 应用自己的界面语言。
 * 切换要重启应用才生效。
 *    `@ohos.i18n.d.ts` 里 `setAppPreferredLanguage` 的原文：
 *    「Resources are loaded in the preferred language when the application is launched.
 *      ... the setting will take effect upon cold starting of the application.」
 *    本文件只负责存偏好与下一次冷启动时应用它，不负责让当前进程立刻换字。
 * 偏好走应用级 preferences（`openAppPrefs`）。语言是两个 HAP 共用的，
 *    用 `UIAbilityContext` 开会变成 entry 与 runtime 各存一份，改了只生效一半。
 */

const DOMAIN = 0x0000;
const TAG = 'UiLanguage';
const STORE = 'ui';
const KEY_LANGUAGE = 'language';

/** 应用自己的界面语言。`System` 表示跟随系统。 */
export enum UiLanguage {
  /** 跟随系统设置。 */
  System,
  /** 简体中文。 */
  Chinese,
  /** English。 */
  English,
}

export const DEFAULT_UI_LANGUAGE: UiLanguage = UiLanguage.System;

/** 全部取值，顺序即设置页下拉里的顺序。 */
export const ALL_UI_LANGUAGES: UiLanguage[] = [
  UiLanguage.System, UiLanguage.Chinese, UiLanguage.English,
];

/**
 * 下拉里显示的名字。
 * 返回 `Resource` 而不是取好的 `string`：`Resource` 自带 `moduleName`
 *    （`api/global/resource.d.ts`：「Application module name」），渲染方按它路由到
 *    本模块的资源表，不需要调用方知道这条字住在哪。
 */
export function uiLanguageLabel(language: UiLanguage): ResourceStr {
  if (language === UiLanguage.Chinese) {
    return $r('app.string.core_language_chinese');
  }
  if (language === UiLanguage.English) {
    return $r('app.string.core_language_english');
  }
  return $r('app.string.core_language_system');
}

/** 存进 preferences 的取值。`default` 是官方给「跟随系统」用的。 */
export function uiLanguageToKey(language: UiLanguage): string {
  if (language === UiLanguage.Chinese) {
    return 'zh-Hans';
  }
  if (language === UiLanguage.English) {
    return 'en';
  }
  return 'default';
}

export function keyToUiLanguage(key: string): UiLanguage {
  if (key === 'zh-Hans') {
    return UiLanguage.Chinese;
  }
  if (key === 'en') {
    return UiLanguage.English;
  }
  return UiLanguage.System;
}

/**
 * 把偏好交给系统。
 * 只在 Ability 启动时调。当前进程里的文案已经按旧语言装配好了，
 *    运行期再调一次不会让已有组件换字 —— 只会让下一次冷启动与这一次不一致。
 */
export function applyUiLanguage(language: UiLanguage): void {
  const tag: string = uiLanguageToKey(language);
  try {
    i18n.System.setAppPreferredLanguage(tag);
    hilog.info(DOMAIN, TAG, 'preferred language set to %{public}s', tag);
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'could not set the preferred language: %{public}s', JSON.stringify(e));
  }
}

/** 冷启动入口：读偏好并应用。读不出来就按跟随系统。 */
export function applyStoredUiLanguage(ctx: common.UIAbilityContext): void {
  applyUiLanguage(readUiLanguageSync(ctx));
}

/**
 * 当前界面是不是英文。
 * 给 rawfile 里的文档用。 资源表由框架按语言自动挑，但 rawfile
 *    没有这个机制 —— 许可声明、使用条款这类长文档要自己选版本。
 * 判据与 `applyUiLanguage` 一致：先看应用偏好，偏好是「跟随系统」时
 *    才去看系统语言。不能只看系统语言 —— 玩家在设置里选了英文、
 *    系统是中文时，文档会和界面语言对不上。
 */
export function isEnglishUi(ctx: common.UIAbilityContext): boolean {
  const pref: UiLanguage = readUiLanguageSync(ctx);
  if (pref === UiLanguage.Chinese) {
    return false;
  }
  if (pref === UiLanguage.English) {
    return true;
  }
  try {
    return i18n.System.getSystemLanguage().toLowerCase().startsWith('en');
  } catch (e) {
    /* 读不到系统语言就按中文 —— 这是应用的主语言。 */
    return false;
  }
}

export async function readUiLanguage(ctx: common.UIAbilityContext): Promise<UiLanguage> {
  const store: preferences.Preferences | null = await openAppPrefs(ctx, STORE);
  if (store === null) {
    return DEFAULT_UI_LANGUAGE;
  }
  try {
    const raw: string = await store.get(KEY_LANGUAGE, uiLanguageToKey(DEFAULT_UI_LANGUAGE)) as string;
    return keyToUiLanguage(raw);
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'could not read the language: %{public}s', JSON.stringify(e));
    return DEFAULT_UI_LANGUAGE;
  }
}

/** 同步版。给 Ability 生命周期用 —— 这里等一个 Promise 会让第一帧先按旧语言画出来。 */
export function readUiLanguageSync(ctx: common.UIAbilityContext): UiLanguage {
  const store: preferences.Preferences | null = openAppPrefsSync(ctx, STORE);
  if (store === null) {
    return DEFAULT_UI_LANGUAGE;
  }
  try {
    return keyToUiLanguage(
      store.getSync(KEY_LANGUAGE, uiLanguageToKey(DEFAULT_UI_LANGUAGE)) as string);
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'could not read the language (sync): %{public}s', JSON.stringify(e));
    return DEFAULT_UI_LANGUAGE;
  }
}

export async function writeUiLanguage(ctx: common.UIAbilityContext,
                                      language: UiLanguage): Promise<void> {
  const store: preferences.Preferences | null = await openAppPrefs(ctx, STORE);
  if (store === null) {
    return;
  }
  try {
    await store.put(KEY_LANGUAGE, uiLanguageToKey(language));
    await store.flush();
    hilog.info(DOMAIN, TAG, 'language set to %{public}s', uiLanguageToKey(language));
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'could not save the language: %{public}s', JSON.stringify(e));
  }
}

/**
 * 取真正要交给 `getStringSync` 的格式化实参。
 * `getStringSync(resource)` 这个单参重载不做占位符替换。
 *    SDK 里是两个重载，说明写得很清楚（`@ohos.resourceManager.d.ts`）：
 *
 *    | 重载 | 官方说明 |
 *    |---|---|
 *    | `getStringSync(resource: Resource)` | 「Obtains a string based on the specified resource object.」 |
 *    | `getStringSync(resource, ...args)` | 「replaces the format placeholders ... using the args parameter」 |
 *
 *    而 `$r('x', 7)` 的实参并不在调用点上 —— 它被塞进了 `Resource.params`
 *    （`resource.d.ts`：「replacement values for formatting APIs」）。
 *    只传 resource 不传 args，等于要求系统「把带占位符的字面串原样给我」，
 *      于是界面上直接露出 `%s days`。
 */
function formatArgsOf(resource: Resource, explicit: (string | number)[]): string[] {
  const raw: (string | number)[] = explicit.length > 0
    ? explicit
    : (resource.params === undefined ? [] : resource.params as (string | number)[]);
  /* 必须逐个转成 `string`，不能把 `number` 原样交给 `getStringSync`。
   *    数字参数会被静默吞掉 —— 占位符解析不出来，该段渲染成空串。
   *    表现是「一整行字没了」或「只剩分隔点」，编译期一字不报。
   *    在这一层统一转换，所有调用点（70 余处）都不用改。 */
  const out: string[] = [];
  for (let i = 0; i < raw.length; i++) {
    const one: string | number = raw[i];
    out.push(one === undefined || one === null ? '' : `${one}`);
  }
  return out;
}

/**
 * 把本模块的一条资源解析成当前语言的 `string`。
 * core 是 HSP，资源表独立。`common/core` 里那 80 个「返回错误串」的函数
 *    （空串 = 成功）签名都是 `string`，调用方靠 `err !== ''` 判成败 ——
 *    一旦让它们返回 `Resource`，这套判据全部失效。所以那条路上**只能在 core 内部
 *    解析成 string**，这里就是那个解析口。
 * 解析失败返回 key 名，绝不返回空串：空串会被调用方读成「没有错误」，
 *    把一次失败静默吞掉。
 */
export function resolveOwnString(ctx: common.UIAbilityContext, res: Resource,
                                 keyName: string, ...args: (string | number)[]): string {
  try {
    /* 同样是「按 id 取」—— 与 `resolveResourceStr` 走同一条路，
     * 否则错误串会停在系统语言，而界面其余部分已经跟着偏好变了。 */
    return getStringByResource(ctx, res, formatArgsOf(res, args));
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'could not resolve %{public}s: %{public}s', keyName, JSON.stringify(e));
    return keyName;
  }
}

/** 设置页「语言」那一行的说明文字。 */
export function languageRestartHint(ctx: common.UIAbilityContext): string {
  return resolveOwnString(ctx, $r('app.string.core_language_hint'), 'core_language_hint');
}

/**
 * 「版本 2.0.0」那一行。
 * `$r` 必须写在资源所属的模块内部。 调用方（entry）写
 *    `$r('app.string.core_about_version')` 会编译失败：
 *    `Unknown resource name 'core_about_version'` —— `$r` 是编译期按当前模块
 *    的资源表解析的，它不知道别的模块有什么字。
 *    跨模块要显示的字，一律由本模块导出返回 `Resource` 的函数，调用方只调函数。
 * 顺带这条也是参数化资源的样本：`%s` 在 json 里，参数在这里传。
 */
export function aboutVersionText(version: string): Resource {
  return $r('app.string.core_about_version', version);
}

/**
 * 按模块名缓存的资源管理器。
 * 为什么要缓存：`createModuleContext` 每次都要做资源查询与初始化，
 *    SDK 的 NOTE 原文写着「Creating a module context involves resource querying
 *    and initialization, which can be time-consuming ... avoid frequently or
 *    repeatedly calling」。而我们的解析函数会被 `build()` 每个重建调用几十次。
 * 只在模块名非空且确实不是当前模块时才查。键就是 `moduleName`。
 */
const moduleManagers: Map<string, resourceManager.ResourceManager> = new Map();

/** 预热过的模块名，按顺序。`moduleName` 空串时用来逐个试。 */
const preloadedOrder: string[] = [];

/**
 * 预热各模块的资源管理器。必须在 `loadContent` 之前 await 完。
 * 为什么不能用同步的 `ctx.createModuleContext(name)`。
 *    它在 SDK 里标了 `@deprecated since 12`，原文：
 *    「You are advised to use `application.createModuleContext` instead.
 *      Otherwise, resource acquisition may fail.」
 *    同步版解不出正确的资源，替代品只有异步版。
 * 预热时机 = 装界面前。 解析函数是同步签名（`build()`、`has()` 里都在调），
 *    只能从缓存取。界面一上屏就不再需要建上下文了。
 * 失败只记日志，不抛 —— 语言是观感，不该挡住启动。某个模块建不出来，
 *    它的文案会走回退（语言可能不对但字出得来）。
 */
export async function preloadModuleManagers(app: common.Context,
                                            names: string[]): Promise<void> {
  for (let i = 0; i < names.length; i++) {
    const name: string = names[i];
    if (name === '' || moduleManagers.has(name)) {
      continue;
    }
    try {
      const moduleCtx: common.Context = await application.createModuleContext(app, name);
      moduleManagers.set(name, moduleCtx.resourceManager);
      preloadedOrder.push(name);
      hilog.info(DOMAIN, TAG, 'module %{public}s is ready', name);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'could not preload module %{public}s: %{public}s',
        name, JSON.stringify(e));
    }
  }
}

/** 按模块名取预热好的管理器。没预热到返回 null，由调用方走回退。 */
function moduleManager(moduleName: string): resourceManager.ResourceManager | null {
  if (moduleName === '') {
    return null;
  }
  const hit: resourceManager.ResourceManager | undefined = moduleManagers.get(moduleName);
  return hit === undefined ? null : hit;
}

/**
 * 解析一条资源，按 id 取（这是语言能正确切换的关键）。
 * `getStringSync(Resource)` 那个重载不跟着应用偏好语言走。
 *    【官方文档】华为开发者问答《HarmonyOS setAppPreferredLanguage部分场景语言未切换》
 *    https://developer.huawei.com/consumer/cn/forum/topic/0204221915110385850
 *    原文：「使用 `setAppPreferredLanguage` 设置语言之后，获取语言资源**只有传入
 *    id 才生效**。不传入 id 拿到的资源和系统设置保持一致。」并给了正误对照：
 *
 *    ```ts
 *    resourceManager.getStringSync($r('app.string.X'));      // ✗ 不跟随应用偏好
 *    resourceManager.getStringSync($r('app.string.X').id);   // ✓
 *    ```
 *
 *    SDK 里那个 `getStringSync(resource: Resource)` 重载也确实标了
 *    `@deprecated since 20`，`@useinstead` 指向按 id 的那个。
 *    症状：`Text($r('...'))` 正常，而**凡是先 `resolveResourceStr()` 转成
 *      string 再显示的文案**（下拉按钮、语言提示、空态、全部 toast）
 *      都停在系统语言。这不是某个页面写错了，是这一条路整体没跟上偏好。
 * 三级回退，任何一步失败退到下一步：
 *    ① 预热好的模块管理器 + `id` —— 语言正确（HSP 的资源走这条）
 *       `Resource.moduleName` 是空串时，把所有预热过的模块逐个试一遍：
 *          它未必填得上（合并资源、跨包引用的场景见过），只看它就会跳过这条修法。
 *    ② 当前上下文的管理器 + `id` —— HAR 的资源被合进宿主，这条也能解
 *    ③ 当前上下文的管理器 + `Resource` 对象 —— 就是旧行为，语言可能不对但字对
 */
function getStringByResource(ctx: common.Context, value: Resource,
                             args: (string | number)[]): string {
  const moduleName: string = value.moduleName ?? '';

  /* ── ① 模块管理器 ─────────────────────────────────────── */
  const named: resourceManager.ResourceManager | null = moduleManager(moduleName);
  if (named !== null) {
    try {
      return named.getStringSync(value.id, ...args);
    } catch (e) {
      hilog.info(DOMAIN, TAG, 'module %{public}s could not resolve %{public}d: %{public}s',
        moduleName, value.id, JSON.stringify(e));
    }
  }
  if (moduleName === '') {
    for (let i = 0; i < preloadedOrder.length; i++) {
      const one: resourceManager.ResourceManager | undefined =
        moduleManagers.get(preloadedOrder[i]);
      if (one === undefined) {
        continue;
      }
      try {
        return one.getStringSync(value.id, ...args);
      } catch (e) {
        /* 这个模块里没有这个 id，试下一个。 */
      }
    }
  }

  /* ── ② 当前上下文 + id ────────────────────────────────── */
  try {
    return ctx.resourceManager.getStringSync(value.id, ...args);
  } catch (e) {
    hilog.info(DOMAIN, TAG, 'own manager could not resolve %{public}d: %{public}s',
      value.id, JSON.stringify(e));
  }

  /* 最后的退路 —— 语言未必对，但至少字出得来。 */
  return ctx.resourceManager.getStringSync(value, ...args);
}

/**
 * 把一条 `ResourceStr` 解析成当期语言的 `string`。
 * 用途是需要拿它做字符串运算的地方 —— 拼接、`join('\n')`、判断空。
 *    `Resource` 是对象，`!== ''` 永远成立、`join` 会拼出 `[object Object]`。
 * 失败返回空串，与 `resolveOwnString` 返回 key 名的策略不同 ——
 *    这里的调用方拿它当「有没有内容」用，给 key 名反而会让空标题占位。
 *    错误消息那条路一律用 `resolveOwnString`。
 * 带参数的 `$r('x', n)` 会自动用 `Resource.params` 填占位符，
 *    调用方不用再把实参重传一遍（见 `formatArgsOf` 的说明）。
 */
export function resolveResourceStr(ctx: common.Context, value: ResourceStr,
                                   ...args: (string | number)[]): string {
  if (typeof value === 'string') {
    return value;
  }
  try {
    return getStringByResource(ctx, value, formatArgsOf(value, args));
  } catch (e) {
    hilog.warn(DOMAIN, TAG, 'could not resolve a resource string: %{public}s',
      JSON.stringify(e));
    return '';
  }
}

/**
 * 逐条解析一组 `ResourceStr`。
 * 不能对 `ResourceStr[]` 直接 `join` —— 元素可能是 `Resource` 对象，
 *    拼出来是 `[object Object]`。一律先过这一层。
 */
export function resolveResourceList(ctx: common.Context, list: ResourceStr[]): string[] {
  const out: string[] = [];
  for (let i = 0; i < list.length; i++) {
    out.push(resolveResourceStr(ctx, list[i]));
  }
  return out;
}

/**
 * 这条文案是不是空的。
 * `ResourceStr` 变量不能用 `value !== ''` 判空。 `Resource` 是对象，
 *    那条判断永远成立 —— 表现是「该隐藏的提示条一直显示」。
 *    编译期一个字都不报，只有真机看得出来。
 * 用于「有话说就显示一条提示」这类条件渲染。
 */
export function isResourceStrEmpty(ctx: common.Context, value: ResourceStr): boolean {
  return resolveResourceStr(ctx, value) === '';
}
