// What ShellApp.swift calls in the engine glue (ShellMain.m).
#include "ShellEngine.h"

#include <TargetConditionals.h>
#if TARGET_OS_MACCATALYST
#import <Foundation/Foundation.h>
NSString * _Nullable dm_shell_read_cli_password(void);
#endif

#include "CatalystHTTPS.h"
