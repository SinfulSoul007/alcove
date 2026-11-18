#import <Foundation/Foundation.h>
#import <JavaScriptCore/JavaScriptCore.h>

#include <cstdio>
#include <cstdlib>

// These symbols are exported by JavaScriptCore. WebKit's own build uses its private header.
extern "C" JSValueRef JSObjectGetPrivateProperty(JSContextRef, JSObjectRef, JSStringRef);
extern "C" bool JSObjectSetPrivateProperty(JSContextRef, JSObjectRef, JSStringRef, JSValueRef);

struct OwnedExtension {
    NSURL *base;
};

static JSValueRef resourceLookup(JSContextRef context, JSObjectRef runtime, JSStringRef key, JSValueRef *)
{
    if (auto existing = JSObjectGetPrivateProperty(context, runtime, key))
        return existing;

    auto *owner = static_cast<OwnedExtension *>(JSObjectGetPrivate(runtime));
    NSURL *base = owner->base;
    JSContext *scriptContext = [JSContext contextWithJSGlobalContextRef:JSContextGetGlobalContext(context)];
    JSValue *function = [JSValue valueWithObject:^JSValue * {
        JSContext *callContext = JSContext.currentContext;
        JSValue *path = JSContext.currentArguments.firstObject;
        if (!path.isString) {
            NSString *message = path ? @"a string is expected" : @"a required argument is missing";
            callContext.exception = [JSValue valueWithNewErrorFromMessage:message inContext:callContext];
            return [JSValue valueWithUndefinedInContext:callContext];
        }

        NSURL *resource = [NSURL URLWithString:path.toString relativeToURL:base];
        if (!resource)
            return [JSValue valueWithNullInContext:callContext];
        return [JSValue valueWithObject:resource.absoluteString inContext:callContext];
    } inContext:scriptContext];
    auto result = function.JSValueRef;
    if (!JSObjectSetPrivateProperty(context, runtime, key, result))
        std::abort();
    return result;
}

int main()
{
    @autoreleasepool {
        JSContext *script = [JSContext new];
        JSGlobalContextRef context = script.JSGlobalContextRef;
        JSStaticValue properties[] = {
            { "getURL", resourceLookup, nullptr, kJSPropertyAttributeNone },
            { nullptr, nullptr, nullptr, kJSPropertyAttributeNone },
        };
        JSClassDefinition definition = kJSClassDefinitionEmpty;
        definition.staticValues = properties;
        auto wrapper = JSClassCreate(&definition);
        OwnedExtension first { [NSURL URLWithString:@"webkit-extension://owned-a/"] };
        OwnedExtension second { [NSURL URLWithString:@"webkit-extension://owned-b/"] };
        script[@"first"] = [JSValue valueWithJSValueRef:JSObjectMake(context, wrapper, &first) inContext:script];
        script[@"second"] = [JSValue valueWithJSValueRef:JSObjectMake(context, wrapper, &second) inContext:script];
        JSClassRelease(wrapper);
        script.exceptionHandler = ^(JSContext *, JSValue *error) {
            std::fprintf(stderr, "FAIL: %s\n", error.toString.UTF8String);
            std::exit(1);
        };
        NSString *checks = @""
            "(function () {"
            "  const check = (ok, message) => { if (!ok) throw Error(message); };"
            "  const expectError = (run, text) => {"
            "      try { run(); } catch (error) { check(error.message.includes(text), text); return; }"
            "      throw Error('Missing validation: ' + text);"
            "  };"
            "  const saved = first.getURL;"
            "  check(typeof saved === 'function', 'ordinary callable');"
            "  check(saved === first.getURL, 'stable identity within an owner');"
            "  check(saved !== second.getURL, 'distinct native owners');"
            "  check(first.getURL('') === 'webkit-extension://owned-a/', 'direct root');"
            "  check(({ lookup: saved }).lookup('assets/logo.png') === 'webkit-extension://owned-a/assets/logo.png', 'copied lookup');"
            "  check(saved.call(second, 'asset.png') === 'webkit-extension://owned-a/asset.png', 'same source with a different receiver');"
            "  check(second.getURL('asset.png') === 'webkit-extension://owned-b/asset.png', 'separate owner URL');"
            "  expectError(() => saved(), 'required argument');"
            "  expectError(() => saved(25), 'a string is expected');"
            "  const names = Reflect.ownKeys(first);"
            "  check(names.length === 1 && names[0] === 'getURL', 'private cache is absent from script properties');"
            "  return true;"
            "})()";
        if (![[script evaluateScript:checks] toBool])
            return 1;
        std::puts("Verified 10 JavaScriptCore callable ownership and validation checks");
    }
}
