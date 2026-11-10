#import "AudioExceptionBridge.h"

NSError *WDPerformAudioSetup(void (^operation)(void)) {
    @try {
        operation();
        return nil;
    } @catch (NSException *exception) {
        if (![exception.name isEqualToString:@"com.apple.coreaudio.avfaudio"]) {
            @throw;
        }
        return [NSError errorWithDomain:@"WhisperDictation.AudioSetup" code:1 userInfo:@{
            NSLocalizedDescriptionKey: @"The microphone changed while starting. Please try recording again.",
            NSLocalizedFailureReasonErrorKey: exception.reason ?: exception.name
        }];
    }
}
