#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Key-value calls on private objects, which raise Objective-C exceptions that Swift cannot catch. Each
// returns nil or NO instead of raising.
id _Nullable WKValueForKey(id object, NSString *key);
BOOL WKSetValueForKey(id object, id _Nullable value, NSString *key);
id _Nullable WKCopy(id object);

NS_ASSUME_NONNULL_END
