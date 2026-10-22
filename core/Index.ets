/**
 * core_oss —— Ark Launcher Pro 的开源核心。
 * 只包含启动器业务里与「数据」有关的部分：存储根、实例与版本隔离、启动计划的
 * 数据契约、游戏语言、游戏设置读写、界面语言、偏好入口。
 * 本模块起不了游戏。把 JVM 拉起来的 native 引导链（`JNI_CreateJavaVM`、
 *    锚库加载、SDL 宿主）在 runtime 里，不在这里。
 * 本模块以 GPL-2.0-only 发布。闭源侧模块 core_internal 单向依赖它。
 * 为什么是 GPL-2 而不是 GPL-3：本模块与 runtime 的 native 引导层共用
 *    `LaunchPlan` 这一套数据结构，而引导层因调用 HotSpot 的 `JNI_CreateJavaVM`
 *    必须是 GPL-2.0-only。GPL-2-only 与 GPL-3.0 互不兼容，两侧取同一个。
 */

/* 界面语言：跟随系统 / 简体中文 / English。切换后要冷启动才生效 */
export {
  UiLanguage,
  DEFAULT_UI_LANGUAGE,
  ALL_UI_LANGUAGES,
  uiLanguageLabel,
  uiLanguageToKey,
  keyToUiLanguage,
  applyUiLanguage,
  applyStoredUiLanguage,
  readUiLanguage,
  readUiLanguageSync,
  writeUiLanguage,
  resolveOwnString,
  resolveResourceStr,
  resolveResourceList,
  isEnglishUi,
  isResourceStrEmpty,
  languageRestartHint,
  aboutVersionText,
  preloadModuleManagers,
} from './src/main/ets/i18n/UiLanguage';

/* 启动计划与结果 */
export {
  LaunchPlan,
  LaunchStage,
  LaunchResult,
  ExitCode,
  createEmptyLaunchPlan,
} from './src/main/ets/launch/LaunchPlan';

/* 上次启动的痕迹（跨进程、跨启动） */
export {
  LaunchRecord,
  PendingSession,
  markAttemptStarted,
  markAttemptFinished,
  consumeSession,
  readLaunchRecord,
  readLaunchRecordSync,
  clearLaunchRecord,
} from './src/main/ets/launch/LaunchRecord';

/* 启动行为偏好：启动后直接进入游戏 / 游戏语言跟随系统 */
export {
  LaunchBehaviour,
  DEFAULT_AUTO_START_GAME,
  DEFAULT_AUTO_LOCALE,
  readLaunchBehaviour,
  readLaunchBehaviourSync,
  writeAutoStartGame,
  writeAutoLocale,
} from './src/main/ets/launch/LaunchPrefs';

/* 操作方式：PC 模式 / 触屏模式。启动参数，改了要重启游戏才生效 */
export {
  ControlMode,
  defaultControlMode,
  controlModeLabel,
  otherControlMode,
  readControlMode,
  readControlModeSync,
  writeControlMode,
} from './src/main/ets/launch/ControlMode';

/* 导入偏好：包要不要改名成版本号、导入时要不要预读存档元数据 */
export {
  JarNaming,
  readJarNaming,
  readJarNamingSync,
  writeJarNaming,
  readParseOnImportSync,
  writeParseOnImport,
} from './src/main/ets/launch/ImportPrefs';

/* 从 zip 里读一个小文本条目（语言清单、版本属性、模组的 mod.hjson） */
export { readJarTextEntry } from './src/main/ets/utils/JarEntry';

/* 游戏语言：从游戏 jar 里读语言清单，把系统语言翻成游戏认得的取值 */
export {
  GameLocale,
  readJarLocales,
  pickGameLocale,
  resolveGameLocale,
} from './src/main/ets/launch/GameLocale';

/* 游戏自己的 settings.bin */
export {
  GameSetting,
  TYPE_BOOL,
  TYPE_INT,
  TYPE_LONG,
  TYPE_FLOAT,
  TYPE_STRING,
  TYPE_BYTES,
  parseSettings,
  serializeSettings,
  loadSettings,
  saveSettings,
  intSetting,
  hasSetting,
  setIntSetting,
} from './src/main/ets/game/SettingsBin';

/* 存储位置：沙箱 / 外部，以及两者的路径 */
export {
  StorageMode,
  bundleName,
  externalRoot,
  rootFor,
  userHomeFor,
  currentUserHome,
  instanceUserHome,
  instanceGameDataDir,
  currentGamesDir,
  gamesDirFor,
  ensureDir,
  dirExists,
  countEntries,
  upgradeLayout,
  readStorageMode,
  readStorageModeSync,
  writeStorageMode,
  DIR_GAMES,
  DIR_EXPORTS,
  DIR_BACKUPS,
} from './src/main/ets/storage/StorageRoot';

/* 档位：只决定之后新导入的包落到哪个实例 */
export {
  Granularity,
  DEFAULT_GRANULARITY,
  ALL_GRANULARITIES,
  granularityLabel,
  granularityToKey,
  keyToGranularity,
  readGranularity,
  readGranularitySync,
  writeGranularity,
} from './src/main/ets/isolation/Granularity';

/* 实例名：目录名即实例名 */
export {
  MAX_INSTANCE_NAME_LEN,
  isValidInstanceName,
  instanceNameError,
} from './src/main/ets/isolation/InstanceName';

/* 实例的数据形状与排序规则（纯数据） */
export { InstanceInfo } from './src/main/ets/isolation/InstanceTypes';

/* 槽位与版本：一个包属于哪一批、它是什么版本、谁高谁低 */
export {
  SLOT_SHARED,
  sharedSlotName,
  slotFor,
  defaultNameForSlot,
  jarVersion,
  instanceVersionText,
  instanceVersionDisplay,
  isDowngrade,
} from './src/main/ets/isolation/InstanceSlot';

/* 实例：一套游戏数据加一个名字。一份实例的读写与导入归位 */
export {
  DIR_INSTANCES,
  instancesDir,
  instanceDir,
  instanceMetaPath,
  listInstances,
  listUnboundInstances,
  findInstance,
  findBySlot,
  uniqueInstanceName,
  createInstance,
  renameInstance,
  duplicateInstance,
  clearInstanceData,
  bindInstanceJar,
  markInstancePlayed,
  ensureInstanceForJar,
} from './src/main/ets/isolation/Instance';

/* 当前选中的实例。首页那张大卡片显示的就是它 */
export {
  readSelected,
  readSelectedSync,
  writeSelected,
  resolveSelected,
  selectInstance,
} from './src/main/ets/isolation/SelectedInstance';

/* 版本：从游戏 jar 里认出它是哪一版 */
export {
  GameVersion,
  readGameVersion,
  versionText,
  versionDisplayText,
} from './src/main/ets/isolation/GameVersion';

/* 游戏进程探测（删游戏包之前要先问一句） */
export {
  GameProcessState,
  gameProcessState,
  canDeleteJar,
} from './src/main/ets/launch/GameProcess';

/* 应用级 preferences（跨 HAP 共用一份） */
export {
  openAppPrefs,
  openAppPrefsSync,
} from './src/main/ets/utils/AppPrefs';

/* 实例的元数据形状与拷贝。闭源侧的排序、分组、回收站要用 */
export { InstanceMeta, cloneMeta } from './src/main/ets/isolation/InstanceTypes';

/* 实例目录的低层读写。闭源侧改完 instance.json 要自己写回 */
export { exists, readMetaAt, writeMetaAt } from './src/main/ets/isolation/Instance';
