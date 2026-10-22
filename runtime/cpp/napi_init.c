//
// Created on 2026/10/17.
//
// 把 libmain.so 对 ArkTS 的两个入口挂上去。
//
// 为什么单独一个文件：main.c 被 SDL_main.h 改了 main 的定义，而 NAPI 头文件
// 与 SDL 头文件属于两套互不相干的系统，挤在同一个编译单元里只为互相干扰。
//
// 为什么是 .c 不是 .cpp：本库保持纯 C，DT_NEEDED 里就不会多出 libc++_shared.so。
// napi/native_api.h 自己带 extern "C" 保护，C 直接用。
//
// 注册必须发生在 dlopen 期间（__attribute__((constructor))）。ArkTS 的
//    import 'libmain.so' 一执行就要在已注册的模块表里找 "main"；写进 main() 里
//    已经太晚 —— main() 要等 SDL 起来才跑，而那时 import 早就发生过了。

#include <napi/native_api.h>
#include "globals.h"

static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        { "setLaunchPlan",   NULL, set_launch_plan,   NULL, NULL, NULL, napi_default, NULL },
        { "getLaunchResult", NULL, get_launch_result, NULL, NULL, NULL, napi_default, NULL },
        { "ackExit",         NULL, ack_exit,          NULL, NULL, NULL, napi_default, NULL },
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

/* nm_modname 必须与库名对得上：libmain.so ⇔ "main"。
 * 这个 "main" 由 SDL 固定（SDL_sysmain_runapp.c 里 "libmain" 是字符串字面量），
 *    不能为了好看改成别的。 */
static napi_module launch_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = NULL,
    .nm_register_func = Init,
    .nm_modname = "main",
    .nm_priv = ((void *)0),
    .reserved = { 0 },
};

void __attribute__((constructor)) RegisterLaunchModule(void)
{
    napi_module_register(&launch_module);
}
