//  Created by Michael Kirk on 12/28/16.
//  Copyright © 2016 Open Whisper Systems. All rights reserved.

@class SignalCall;

@protocol OWSCallNotificationsAdaptee <NSObject>

- (void)presentIncomingCall:(SignalCall *)call
                 callerName:(NSString *)callerName NS_SWIFT_NAME(presentIncomingCall(_:callerName:));

@end
