import WebKit
import ObjectiveC

@MainActor enum BrowserWebPreferences {
    static func enableIdleCallbacks(in preferences:WKPreferences) {
        let listSelector = NSSelectorFromString("_features"),setSelector = NSSelectorFromString("_setEnabled:forFeature:")
        guard let listMethod = class_getClassMethod(WKPreferences.self,listSelector),
              let setMethod = class_getInstanceMethod(WKPreferences.self,setSelector) else {return}
        typealias ListFeatures = @convention(c) (AnyClass,Selector) -> Unmanaged<NSArray>?
        typealias SetFeature = @convention(c) (AnyObject,Selector,ObjCBool,AnyObject) -> Void
        let features = unsafeBitCast(method_getImplementation(listMethod),to:ListFeatures.self)(WKPreferences.self,listSelector)?.takeUnretainedValue() as? [NSObject] ?? []
        let keySelector = NSSelectorFromString("key")
        guard let feature = features.first(where:{feature in
            feature.responds(to:keySelector) && feature.perform(keySelector)?.takeUnretainedValue() as? String == "RequestIdleCallbackEnabled"
        }) else {return}
        // Enable the existing native scheduler on this configuration only.
        unsafeBitCast(method_getImplementation(setMethod),to:SetFeature.self)(preferences,setSelector,ObjCBool(true),feature)
    }
}
