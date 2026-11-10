#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// AVFAudio raises Objective-C exceptions that Swift do/catch cannot intercept.
FOUNDATION_EXPORT NSError * _Nullable WDPerformAudioSetup(NS_NOESCAPE void (^operation)(void));
NS_ASSUME_NONNULL_END
