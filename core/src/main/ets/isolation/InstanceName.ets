/**
 * 实例名的判据。单独一个文件，因为它是磁盘上真正的边界。
 * 实例名同时是目录名。任何拼路径的地方都要先过这里，否则玩家输入里的
 * `/` 或 `..` 会让操作跑到 `<数据根>/instances/` 外面去。
 */

import { common } from '@kit.AbilityKit';
import { resolveOwnString } from '../i18n/UiLanguage';

/** 名字最长多少字符。留足余量给 `<根>/instances/<名字>/.local/share/Mindustry` 这条路径。 */
export const MAX_INSTANCE_NAME_LEN: number = 48;

/** 路径里不能出现的字符，外加控制字符。 */
const BAD_NAME_CHARS = /[\/\\:*?"<>|\x00-\x1f]/;

/**
 * 名字不合法时的资源键名（合法时返回空串）。
 * 纯函数、不碰 ctx：判合法性（`isValidInstanceName`）和内部校验只看
 *    「是不是空串」，不需要把文案解析出来。展示给用户的那条路走
 *    `instanceNameError`（带 ctx），由它把键名解析成当前语言的 string。
 */
export function instanceNameErrorKey(name: string): string {
  if (name === '') {
    return 'core_name_err_empty';
  }
  if (name.length > MAX_INSTANCE_NAME_LEN) {
    return 'core_name_err_too_long';
  }
  if (name === '.' || name === '..') {
    return 'core_name_err_reserved';
  }
  if (BAD_NAME_CHARS.test(name)) {
    return 'core_name_err_bad_chars';
  }
  if (name !== name.trim()) {
    return 'core_name_err_space_edges';
  }
  if (name.charAt(0) === '.' || name.charAt(name.length - 1) === '.') {
    return 'core_name_err_dot_edges';
  }
  return '';
}

/**
 * 这个名字能不能当目录名。
 * 拒绝而不是净化：玩家输入什么，目录就叫什么。静默改字符会让他照着界面上的名字
 * 去文件管理器里找不到那个目录。
 */
export function isValidInstanceName(name: string): boolean {
  return instanceNameErrorKey(name) === '';
}

/** 名字不合法时的说明。合法时返回空串。 */
export function instanceNameError(ctx: common.UIAbilityContext, name: string): string {
  const key = instanceNameErrorKey(name);
  if (key === '') {
    return '';
  }
  if (key === 'core_name_err_too_long') {
    return resolveOwnString(ctx, $r('app.string.core_name_err_too_long', MAX_INSTANCE_NAME_LEN),
      'core_name_err_too_long');
  }
  if (key === 'core_name_err_empty') {
    return resolveOwnString(ctx, $r('app.string.core_name_err_empty'), 'core_name_err_empty');
  }
  if (key === 'core_name_err_reserved') {
    return resolveOwnString(ctx, $r('app.string.core_name_err_reserved'), 'core_name_err_reserved');
  }
  if (key === 'core_name_err_bad_chars') {
    return resolveOwnString(ctx, $r('app.string.core_name_err_bad_chars'), 'core_name_err_bad_chars');
  }
  if (key === 'core_name_err_space_edges') {
    return resolveOwnString(ctx, $r('app.string.core_name_err_space_edges'), 'core_name_err_space_edges');
  }
  return resolveOwnString(ctx, $r('app.string.core_name_err_dot_edges'), 'core_name_err_dot_edges');
}
