//
// Created on 2026/10/17.
//

#include <napi/native_api.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include "globals.h"

/* 全进程唯一的一份启动计划。定义在这里，声明在 globals.h。
 * 写入与读取分处两个线程：GameAbility 在主线程调 setLaunchPlan，SDL 另起线程调 main()。
 * 两者之间的顺序由「线程创建」保证 —— GameAbility 必须先等 setLaunchPlan 返回、
 * 才允许触发 SDL，故 main() 读到的必然是写完的 g_plan，不加锁。 */
LaunchPlan g_plan;

/* 全部清零。stage / exit_code 也归零 —— 它们是「这一次启动」的结果，
 * 上一次的残值留着会让 ArkTS 把新的一次当成旧的那次。
 * 原子字段不参与 memset：标准只承认通过原子操作访问 _Atomic 变量，
 * 拿 memset 越过它们是「实践上可行、标准上不严谨」。故清零到 stage 为止，
 * 之后的原子字段与 valid 逐个赋值。 */
static void plan_reset(void)
{
    memset(&g_plan, 0, offsetof(LaunchPlan, stage));
    atomic_store(&g_plan.stage, PLAN_STAGE_NONE);
    atomic_store(&g_plan.exit_code, 0);
    atomic_store(&g_plan.finished, 0);
    atomic_store(&g_plan.exit_ack, 0);
    g_plan.valid = 0;
}

/* 读一个字符串属性。属性不存在、类型不是 string、长到装不下 —— 三种都算「没给」，
 * 保持空串。失败聚合成字段缺省而不作废整份计划：缺省值都是安全的（不生效），
 * 作废会让一次本来能跑的启动变成不能跑。 */
static bool read_string_prop(napi_env env, napi_value obj, const char *name,
                             char *buf, size_t cap)
{
    buf[0] = '\0';

    napi_value v;
    if (napi_get_named_property(env, obj, name, &v) != napi_ok) {
        return false;
    }

    napi_valuetype t;
    if (napi_typeof(env, v, &t) != napi_ok || t != napi_string) {
        return false;
    }

    /* 先问长度再取。napi_get_value_string_utf8 会静默截断，而截断后的路径在
     * fopen / dlopen 上表现为「文件不存在」—— 最难查的一类失败。 */
    size_t need = 0;
    if (napi_get_value_string_utf8(env, v, NULL, 0, &need) != napi_ok) {
        return false;
    }
    if (need >= cap) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                     "plan: '%s' needs %zu bytes (buffer is %zu) -- ignored",
                     name, need + 1, cap);
        return false;
    }
    if (napi_get_value_string_utf8(env, v, buf, cap, &need) != napi_ok) {
        buf[0] = '\0';
        return false;
    }
    return true;
}

/* 读一个开关字段，boolean 与 0/1 都认。
 * 只认 boolean 的话，ArkTS 侧一旦传成数字就被整条丢弃，而症状是
 * 「devNogame 明明传了却不生效」—— 静默失效。多认一种类型比多查一次划算。 */
static bool read_bool_prop(napi_env env, napi_value obj, const char *name, int *out)
{
    *out = 0;

    napi_value v;
    if (napi_get_named_property(env, obj, name, &v) != napi_ok) {
        return false;
    }

    napi_valuetype t;
    if (napi_typeof(env, v, &t) != napi_ok) {
        return false;
    }
    if (t == napi_boolean) {
        bool b = false;
        if (napi_get_value_bool(env, v, &b) != napi_ok) {
            return false;
        }
        *out = b ? 1 : 0;
        return true;
    }
    if (t == napi_number) {
        int32_t n = 0;
        if (napi_get_value_int32(env, v, &n) != napi_ok) {
            return false;
        }
        *out = (n != 0) ? 1 : 0;
        return true;
    }
    return false;
}

/* 读追加的 JVM 选项。逐条校验长度，装不下的那条丢掉并报出来，
 * 而不是让后面的条目整体偏移 —— 选项错位在 JVM 侧只表现为「某个开关没生效」。 */
static void read_extra_opts(napi_env env, napi_value obj)
{
    napi_value arr;
    if (napi_get_named_property(env, obj, "extraOpts", &arr) != napi_ok) {
        return;
    }

    bool is_arr = false;
    if (napi_is_array(env, arr, &is_arr) != napi_ok || !is_arr) {
        return;
    }

    uint32_t len = 0;
    if (napi_get_array_length(env, arr, &len) != napi_ok) {
        return;
    }

    for (uint32_t i = 0; i < len; i++) {
        if (g_plan.extra_count >= MAX_EXTRA_OPTS) {
            SDL_Log("plan: extraOpts has %u entries, only the first %d are kept",
                    (unsigned) len, MAX_EXTRA_OPTS);
            break;
        }

        napi_value item;
        if (napi_get_element(env, arr, i, &item) != napi_ok) {
            continue;
        }

        napi_valuetype t;
        if (napi_typeof(env, item, &t) != napi_ok || t != napi_string) {
            SDL_Log("plan: extraOpts[%u] is not a string -- dropped", (unsigned) i);
            continue;
        }

        size_t need = 0;
        if (napi_get_value_string_utf8(env, item, NULL, 0, &need) != napi_ok) {
            continue;
        }
        if (need >= EXTRA_OPT_CAP) {
            SDL_Log("plan: extraOpts[%u] needs %zu bytes (cap is %d) -- dropped",
                    (unsigned) i, need + 1, EXTRA_OPT_CAP);
            continue;
        }
        if (napi_get_value_string_utf8(env, item,
                                       g_plan.extra_opts[g_plan.extra_count],
                                       EXTRA_OPT_CAP, &need) != napi_ok) {
            continue;
        }
        g_plan.extra_count++;
    }
}

/* 把这份计划打进 hilog。启动失败后第一件要回答的事是「当时给的是哪些参数」，
 * 而 g_plan 在进程死掉之后什么都不剩。写日志不落文件 —— 文件在下次启动前
 * 还得有人清，日志不用。 */
static void plan_write_log(void)
{
    SDL_Log(" --- launch plan ---");
    SDL_Log("   game jar  : %s", g_plan.game_jar[0] ? g_plan.game_jar : "(none)");
    SDL_Log("   mods dir  : %s", g_plan.mods_dir[0] ? g_plan.mods_dir : "(default under user.home)");
    SDL_Log("   user.home : %s", g_plan.user_home[0] ? g_plan.user_home : "(none)");

    if (g_plan.locale_lang[0]) {
        SDL_Log("   locale    : %s%s%s",
                g_plan.locale_lang,
                g_plan.locale_country[0] ? ", " : "",
                g_plan.locale_country);
    } else {
        SDL_Log("   locale    : (system default)");
    }

    SDL_Log("   mobile    : %d", g_plan.mobile);
    SDL_Log("   exec mem  : %d", g_plan.exec_mem_ok);
    SDL_Log("   dev flags : nogame=%d nohandlers=%d minimal=%d noexec=%d",
            g_plan.dev_nogame, g_plan.dev_nohandlers,
            g_plan.dev_minimal, g_plan.dev_noexec);
    SDL_Log("   extra opts: %d", g_plan.extra_count);
    for (int i = 0; i < g_plan.extra_count; i++) {
        SDL_Log("     [%d] %s", i, g_plan.extra_opts[i]);
    }
    SDL_Log("   valid     : %d", g_plan.valid);
    SDL_Log(" --- end of plan ---");
}

/* ArkTS 侧：setLaunchPlan({...}) —— GameAbility 在触发 SDL 之前调一次。
 * 调不到、或参数不是对象，valid 就停在 0，main() 会当场拒绝启动并说明原因。 */
napi_value set_launch_plan(napi_env env, napi_callback_info info)
{
    napi_value undef;
    napi_get_undefined(env, &undef);

    size_t argc = 1;
    napi_value argv[1] = { NULL };
    if (napi_get_cb_info(env, info, &argc, argv, NULL, NULL) != napi_ok || argc < 1) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                     "setLaunchPlan: expected one object argument -- not called?");
        return undef;
    }

    napi_valuetype t;
    if (napi_typeof(env, argv[0], &t) != napi_ok || t != napi_object) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                     "setLaunchPlan: the argument is not an object -- the launch will be refused");
        return undef;
    }

    plan_reset();

    read_string_prop(env, argv[0], "gameJar",       g_plan.game_jar,       sizeof(g_plan.game_jar));
    read_string_prop(env, argv[0], "modsDir",       g_plan.mods_dir,       sizeof(g_plan.mods_dir));
    read_string_prop(env, argv[0], "userHome",      g_plan.user_home,      sizeof(g_plan.user_home));
    read_string_prop(env, argv[0], "localeLang",    g_plan.locale_lang,    sizeof(g_plan.locale_lang));
    read_string_prop(env, argv[0], "localeCountry", g_plan.locale_country, sizeof(g_plan.locale_country));

    /* mobile 在 ArkTS 侧是 boolean —— 用 read_bool_prop 而不是读数字，
     * 否则类型对不上、整条丢弃，症状是「平板拿到 WASD 键位」。 */
    read_bool_prop(env, argv[0], "mobile",        &g_plan.mobile);
    read_bool_prop(env, argv[0], "execMemOk",     &g_plan.exec_mem_ok);
    read_bool_prop(env, argv[0], "devNogame",     &g_plan.dev_nogame);
    read_bool_prop(env, argv[0], "devNohandlers", &g_plan.dev_nohandlers);
    read_bool_prop(env, argv[0], "devMinimal",    &g_plan.dev_minimal);
    read_bool_prop(env, argv[0], "devNoexec",     &g_plan.dev_noexec);

    read_extra_opts(env, argv[0]);

    /* 所有字段都有安全缺省，所以走到这里就说明计划可用 —— valid 只回答
     * 「setLaunchPlan 有没有被正常调用过」，与 ExitCode.NoLaunchPlan 同名同义。
     * userHome 留空是合法的：resolve_user_home() 会退回 g_data_root，
     *    而那是 native 自己用平台 API 取的应用级目录，比 ArkTS 侧推的准。
     *    「不隔离」本来就是这个意思。隔离功能实现后由 ArkTS 填具体路径。
     * 绝对路径与 ".." 的判据留在 resolve_user_home() —— 那里还要回退、还要记日志，
     * 判据两份会分叉。 */
    if (g_plan.user_home[0] != '\0' && g_plan.user_home[0] != '/') {
        SDL_Log(" setLaunchPlan: userHome is not absolute -- falling back to the data root");
        g_plan.user_home[0] = '\0';
    }

    g_plan.valid = 1;

    plan_write_log();
    return undef;
}

/* ArkTS 侧：getLaunchResult() —— 启动之后轮询。
 * 它存在的理由只有一个：JNI_CreateJavaVM 拿不到它要的东西时，进程会当场停死，
 * 不留日志、不留 faultlog、不留返回码。那时 ArkTS 能看到的是「stage 停在 NONE
 * 而进程没了」，这是唯一能识别那种失败的办法，所以 init 结束就要置 JVM。 */
napi_value get_launch_result(napi_env env, napi_callback_info info)
{
    (void) info;

    napi_value undef;
    napi_get_undefined(env, &undef);

    napi_value obj;
    if (napi_create_object(env, &obj) != napi_ok) {
        return undef;
    }

    napi_value v;

    if (napi_create_int32(env, atomic_load(&g_plan.stage), &v) == napi_ok) {
        napi_set_named_property(env, obj, "stage", v);
    }
    if (napi_create_int32(env, atomic_load(&g_plan.exit_code), &v) == napi_ok) {
        napi_set_named_property(env, obj, "exitCode", v);
    }
    if (napi_create_int32(env, atomic_load(&g_plan.finished), &v) == napi_ok) {
        napi_set_named_property(env, obj, "finished", v);
    }
    if (napi_create_int32(env, g_plan.valid, &v) == napi_ok) {
        napi_set_named_property(env, obj, "valid", v);
    }

    return obj;
}

/* ArkTS 侧：ackExit() —— 处理完毕，native 可以退出。
 * 没有它，native 只能在「置 finished 之后固定睡一段时间然后杀掉自己」——
 *    那段时间要么短到玩家看不清面板，要么长到每次正常退出都拖一截。
 *    有了它，native 等的就是「真的处理完了」这个事件。
 * 无条件置位：重复调用、在 finished 之前调用都无害。它只是一个开关，
 *    早一点打开不会跳过任何东西 —— main() 那边是先置 finished 才去看它的。 */
napi_value ack_exit(napi_env env, napi_callback_info info)
{
    (void) info;

    atomic_store(&g_plan.exit_ack, 1);

    napi_value undef;
    napi_get_undefined(env, &undef);
    return undef;
}
