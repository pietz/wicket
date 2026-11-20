#import "ObjCBoundary.h"

id WKValueForKey(id object, NSString *key) {
  @try {
    return [object valueForKey:key];
  } @catch (NSException *exception) {
    return nil;
  }
}

BOOL WKSetValueForKey(id object, id value, NSString *key) {
  @try {
    [object setValue:value forKey:key];
    return YES;
  } @catch (NSException *exception) {
    return NO;
  }
}

id WKCopy(id object) {
  @try {
    return [object conformsToProtocol:@protocol(NSCopying)] ? [object copy] : nil;
  } @catch (NSException *exception) {
    return nil;
  }
}
