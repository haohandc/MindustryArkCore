/**
 * 页面与 UIAbility 之间的单向通道。
 * 为什么需要：ArkUI 页面拿不到 Ability 实例。页面能改的只有 AppStorage，
 * 而 AppStorage 不能可靠地存函数。所以 GameAbility 在 onCreate 时把自己的
 * 处理函数登记到这里，页面直接调。
 * 只有一条边：页面 → Ability。反方向（进度、面板）一律走 AppStorage，
 *    因为那边需要的是「值变了页面重绘」，而不是「调一个函数」。
 */

type VoidHandler = () => void;

class AbilityBridgeImpl {
  private dismissHandler: VoidHandler | null = null;

  /** GameAbility 在 onCreate 里登记。重复登记覆盖上一条 —— 一个进程只有一个 GameAbility。 */
  registerDismiss(handler: VoidHandler): void {
    this.dismissHandler = handler;
  }

  /** Ability 销毁时清掉，免得页面调到一个已死的实例。 */
  unregister(): void {
    this.dismissHandler = null;
  }

  /** 页面调：玩家看完了面板。没有登记时什么也不做（预览器里就是这种情况）。 */
  dismissPanel(): void {
    if (this.dismissHandler !== null) {
      this.dismissHandler();
    }
  }
}

export const abilityBridge: AbilityBridgeImpl = new AbilityBridgeImpl();
