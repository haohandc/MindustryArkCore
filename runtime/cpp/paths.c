//
// Created on 2026/10/16.
//
// Node APIs are not fully supported. To solve the compilation error of the interface cannot be found,
// please include "napi/native_api.h".

#include <dlfcn.h>         // dladdr
#include <errno.h>
#include <stdint.h>        // int32_t / uintptr_t
#include <string.h>        // strlen / strstr / memcpy / strerror
#include <sys/stat.h>      // mkdir / stat
#include <AbilityKit/ability_runtime/application_context.h>
#include "globals.h"

/* 定义运行期路径缓冲区 —— 尺寸取 globals.h 的宏 */
char g_libroot[G_LIBROOT_CAP];
char g_jdkhome[G_JDKHOME_CAP];
char g_jdklib[G_JDKLIB_CAP];
char g_anchor[G_ANCHOR_CAP];
char g_data_root[G_DATAROOT_CAP];
char g_tmp_dir[G_TMPDIR_CAP];
char g_exit_marker[G_EXITMARK_CAP];
char g_sandbox_jdk[G_SANDBOXJDK_CAP];

/* 拼接两个路径分量，超长则清空并报错。
 * 长度必须显式查 —— SDL_snprintf 会静默截断，而截断后的路径在 fopen / dlopen
 *    上表现为「文件不存在」，是最难归因的一类失败。 */
static bool join_paths(char *dest, size_t cap, const char *prefix, const char *suffix)
{
    int n = SDL_snprintf(dest, cap, "%s%s", prefix, suffix);
    if (n < 0 || (size_t) n >= cap) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                     "path would need %d bytes (buffer %zu): %s%s", n, cap, prefix, suffix);
        dest[0] = '\0';
        return false;
    }
    return true;
}

/* 绝对路径且不含 ".."。判据宁严勿宽：这些值最后会拼进 dlopen / mkdir */
static bool is_valid_absolute_path(const char *path)
{
    if (path[0] != '/') {
        return false;
    }
    if (strstr(path, "..") != NULL) {
        return false;
    }
    return true;
}

/* 逐层创建目录，已存在不算失败。
 * 与 mkdir 的区别：路径中间那几层也建。user.home 可能是
 * <数据根>/instances/<键>/sets/default 这样的深路径。 */
static bool mkdir_p(const char *path)
{
    char tmp[G_DATAROOT_CAP];
    if (SDL_strlcpy(tmp, path, sizeof(tmp)) >= sizeof(tmp)) {
        SDL_Log(" !! path too long to create: %s", path);
        return false;
    }

    size_t n = strlen(tmp);
    while (n > 1 && tmp[n - 1] == '/') {
        tmp[--n] = '\0';
    }

    for (char *p = tmp + 1; *p != '\0'; p++) {
        if (*p != '/') {
            continue;
        }
        *p = '\0';
        if (mkdir(tmp, 0755) != 0 && errno != EEXIST) {
            SDL_Log(" !! mkdir %s: %s", tmp, strerror(errno));
            return false;
        }
        *p = '/';
    }

    if (mkdir(tmp, 0755) != 0 && errno != EEXIST) {
        SDL_Log(" !! mkdir %s: %s", tmp, strerror(errno));
        return false;
    }
    return true;
}

/* 向平台问一个应用级目录，写进 buf。
 * 返回的是【应用级】目录（/data/storage/el2/base/files），不是模块级的
 *    /data/storage/el2/base/haps/<模块>/files —— 双 HAP 下模块级路径会错位。 */
static bool query_app_dir(const char *label, char *buf, size_t cap,
                          AbilityRuntime_ErrorCode (*getter)(char *, int32_t, int32_t *))
{
    buf[0] = '\0';

    int32_t written = 0;
    AbilityRuntime_ErrorCode rc = getter(buf, (int32_t) cap, &written);
    if (rc != ABILITY_RUNTIME_ERROR_CODE_NO_ERROR) {
        SDL_Log(" !! %s: platform returned %d", label, (int) rc);
        buf[0] = '\0';
        return false;
    }
    if (written < 0 || (size_t) written >= cap) {
        SDL_Log(" !! %s: platform says %d bytes (buffer %zu)", label, (int) written, cap);
        buf[0] = '\0';
        return false;
    }
    return true;
}

/**
 * 启动最早期跑一次，后面所有路径都依赖它。
 * 两侧来源不同：
 *   HAP 侧（JDK、锚库、Arc natives）—— dladdr 算出本库真实位置再拼，落不到时用编译期猜测。
 *   沙箱侧（数据根、临时目录）—— 问平台，不硬编码。
 * @return  1: 全部来自运行时发现
 *          0: dladdr 失败，HAP 侧用了编译期猜测（仍可继续）
 *         -1: 拿不到沙箱路径，后面什么都做不了
 */
int discover_paths(void)
{
    /* ---------- HAP 侧 ---------- */
    Dl_info dl;
    SDL_memset(&dl, 0, sizeof(dl));

    g_libroot[0] = '\0';
    if (dladdr((void *)(uintptr_t)&discover_paths, &dl) && dl.dli_fname) {
        if (SDL_strlcpy(g_libroot, dl.dli_fname, sizeof(g_libroot)) >= sizeof(g_libroot)) {
            SDL_LogError(SDL_LOG_CATEGORY_APPLICATION, "g_libroot truncated: %s", dl.dli_fname);
            g_libroot[0] = '\0';
        }
        char *slash = SDL_strrchr(g_libroot, '/');
        if (slash) {
            *slash = '\0';
        }
        SDL_Log(" dladdr says this library is      : %s", dl.dli_fname);
        SDL_Log(" -> so the native lib dir is      : %s", g_libroot);
    } else {
        SDL_Log(" !! dladdr failed -- falling back to the compile-time guess");
    }

    const int discovered = (g_libroot[0] != '\0');
    if (!discovered) {
        SDL_strlcpy(g_libroot, BUNDLE_LIBS, sizeof(g_libroot));
    }

    if (!join_paths(g_jdkhome, sizeof(g_jdkhome), g_libroot, "/jdk"))             return -1;
    if (!join_paths(g_jdklib,  sizeof(g_jdklib),  g_jdkhome, "/lib"))             return -1;
    if (!join_paths(g_anchor,  sizeof(g_anchor),  g_libroot, "/libjvm.so"))       return -1;

    /* 编译期猜的那个路径必须真的存在 —— 锚库的 DT_NEEDED 指向它，写错了运行期修不了。 */
    struct stat st;
    if (stat(BUNDLE_LIBS "/libjvm.so", &st) != 0) {
        SDL_Log(" !! the anchor is not at the compile-time path %s/libjvm.so", BUNDLE_LIBS);
        SDL_Log("    the anchor's baked-in DT_NEEDED points there too -- it cannot be fixed at runtime");
        SDL_Log("    rebuild with: python scripts/prep_vendor.py, DEVICE_JVM = %s/", g_libroot);
    }

    /* ---------- 沙箱侧 ---------- */
    if (!query_app_dir("filesDir", g_data_root, sizeof(g_data_root),
                       OH_AbilityRuntime_ApplicationContextGetFilesDir)) {
        SDL_Log(" !! without the application files dir there is nowhere to assemble java.home");
        return -1;
    }
    if (!query_app_dir("tempDir", g_tmp_dir, sizeof(g_tmp_dir),
                       OH_AbilityRuntime_ApplicationContextGetTempDir)) {
        SDL_Log(" !! without the application temp dir -Djava.io.tmpdir cannot be set");
        return -1;
    }

    if (!join_paths(g_exit_marker,  sizeof(g_exit_marker),  g_data_root, "/native_exit")) return -1;
    if (!join_paths(g_sandbox_jdk,  sizeof(g_sandbox_jdk),  g_data_root, "/jdk"))         return -1;

    SDL_Log(" data root                        : %s", g_data_root);
    SDL_Log(" temp dir                         : %s", g_tmp_dir);
    SDL_Log(" java.home (to be assembled)      : %s", g_sandbox_jdk);

    return discovered;
}

/* 算出这次启动该用的 user.home，写进 buf。
 * 决策在 ArkTS 侧：不隔离 = 数据根本身；隔离 = <数据根>/instances/<键>/sets/default。
 * 路径与键的字符集由 ArkTS 组装并校验，这里只做三件事：
 *   ① 确认是绝对路径、不含 ".."；② 逐层建目录；③ 任何一步失败都退回数据根。
 * 退回数据根而不是失败退出：分区或键坏了不该让游戏完全没法跑，
 *    但必须留下日志说明退回过。 */
void resolve_user_home(char *buf, size_t cap)
{
    const char *want = g_plan.user_home;

    if (want[0] == '\0') {
        SDL_Log(" user.home: the plan has none -- using the data root");
        want = NULL;
    } else if (!is_valid_absolute_path(want)) {
        SDL_Log(" user.home: rejecting '%s' (not absolute, or contains '..') -- using %s",
                want, g_data_root);
        want = NULL;
    } else if (!mkdir_p(want)) {
        SDL_Log(" user.home: cannot create '%s' -- using %s", want, g_data_root);
        want = NULL;
    }

    /* 回退与正常路径都要查截断：-Duser.home 被截断会让存档落到别的地方，
     * 而症状是「存档不见了」，与这里毫无关联。 */
    const char *value = (want != NULL) ? want : g_data_root;
    if (SDL_strlcpy(buf, value, cap) >= cap) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                     "user.home would need %zu bytes (buffer %zu): %s",
                     strlen(value) + 1, cap, value);
        buf[0] = '\0';
        return;
    }

    SDL_Log(" user.home: %s", buf);
}
