#import "BaseAuthenticator.h"
#include "jni.h"

JNIEXPORT jstring JNICALL Java_net_kdt_pojavlaunch_value_MinecraftAccount_getAccessTokenFromKeychain(JNIEnv *env, jclass clazz, jstring xuid) {
    // 修复：原版实现只允许调用一次（第二次直接 abort() 崩溃），且无 nil 检查。
    // 现在：允许多次调用；Keychain 读不到或参数为空时返回空字符串，绝不崩溃。
    if (xuid == NULL) {
        return (*env)->NewStringUTF(env, "");
    }

    const char *xuidC = (*env)->GetStringUTFChars(env, xuid, 0);
    NSString *accessToken = [NSClassFromString(@"MicrosoftAuthenticator") tokenDataOfProfile:@(xuidC)][@"accessToken"];
    (*env)->ReleaseStringUTFChars(env, xuid, xuidC);
    if (accessToken == nil) {
        return (*env)->NewStringUTF(env, "");
    }
    return (*env)->NewStringUTF(env, accessToken.UTF8String);
}
