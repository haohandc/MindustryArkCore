# MindustryArkCore

Ark Launcher 的开源核心与运行时引导层。

本仓库提供在 HarmonyOS 上启动 JVM 并运行 Java 游戏所需的最小实现集合，分数据层与引导层两部分。

## 组成

`core/` 为数据层，纯 ArkTS 实现，包含实例隔离、存储布局、启动计划的数据契约、游戏设置读写与界面语言。

`runtime/` 为引导层，负责 JVM 启动链：加载锚库、调用 `JNI_CreateJavaVM`、在沙箱中铺设 `java.home` 目录树、承载 SDL 窗口。

## 边界

以下内容不在本仓库中：

- JDK 运行时。`libjvm.so` 与 `libjvm_real.so` 须自行准备。
- 游戏本体。
- 启动器界面。界面实现属于 Ark Launcher，闭源。
- 完整 SDL 源码树。本仓库仅提供被修改的 6 个文件，见「SDL3 集成」。

## 目录结构

```
core/                     ArkTS 模块，ohpm 包名 core_oss
  Index.ets               对外出口，147 个导出名
  oh-package.json5        许可 GPL-2.0-only
  src/main/ets/           19 个源文件
  src/main/resources/     中英字符串表各 42 条
runtime/
  cpp/                    8 个自有文件与 CMakeLists.txt
  ets/                    4 个文件：GameAbility、AbilityBridge、ImeBridge、页面
third_party/
  jni/                    OpenJDK 上游原文，保留原许可头
  SDL/modified/           被修改的 6 个 SDL 文件，见 NOTICE.md
```

## 跨模块数据契约

`runtime/cpp/plan.c` 以字段名取值，接收 ArkTS 侧传入的对象，涉及 11 个字段：

```
gameJar  modsDir  userHome  localeLang  localeCountry  mobile  execMemOk
devNogame  devNohandlers  devMinimal  devNoexec
```

字段定义见 `core/src/main/ets/launch/LaunchPlan.ets` 的 `LaunchPlan` 接口。

该契约不具备编译期校验。ArkTS 侧修改字段名后，cpp 侧不产生编译错误，运行时取值为空或默认值，现象为启动失败且无错误日志。

## 构建条件

1. DevEco Studio，`compatibleSdkVersion` 6.1.1(24)，`targetSdkVersion` 26.0.0
2. JDK 载荷，含 HotSpot 与 class library，置于构建流程约定的位置
3. SDL3 鸿蒙后端，按「SDL3 集成」一节组装
4. `runtime/` 需要 `ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY`。该权限仅 Tablet 与 2in1 支持，手机不可用

## SDL3 集成

`runtime/cpp/` 依赖 SDL3 鸿蒙后端。完整源码树包含 1,703 个文件，约 37 MB，本仓库不收录。

本仓库提供被修改的 6 个文件，位于 `third_party/SDL/modified/`。组装方式：

1. 从 `libsdl-org/SDL` 的 `main` 分支获取源码
2. 以 `third_party/SDL/modified/` 下的 6 个文件覆盖对应路径
3. 修改的必要性见 `third_party/SDL/NOTICE.md`

```bash
curl -L -o sdl.tar.gz https://codeload.github.com/libsdl-org/SDL/tar.gz/refs/heads/main
tar xzf sdl.tar.gz
# 用 third_party/SDL/modified/ 下的 6 个文件覆盖 SDL-main/src/ 对应路径
```

这 6 个文件为修改版，并非上游原文。zlib 许可要求对修改版作出显著标注，引用时不得描述为原版 SDL3。

上述文件取自 `main` 分支的某一时刻，未记录 commit SHA，因此无法保证与上游任一提交逐字节对应。

## 许可

GPL-2.0-only，全文见 [LICENSE](LICENSE)。

### 第三方组件

| 目录 | 许可 | 说明 |
|---|---|---|
| `third_party/jni/` | GPL-2 + Classpath Exception | OpenJDK 上游原文，保留原文件头 |
| `third_party/SDL/modified/` | zlib | SDL3 修改版，原许可见上游 `LICENSE.txt` |

## 关于 Pull Request

本仓库为 Ark Launcher 的开源代码镜像，开发工作在主仓库进行，不接受 Pull Request。Issue 仅用于反馈，不构成对本仓库作出修改的承诺。

## 相关仓库

- Ark Launcher：应用本体，闭源
- MindustryArk：v1 版本历史归档
