//  Created by Michael Kirk on 12/28/16.
//  Copyright © 2016 Open Whisper Systems. All rights reserved.

@protocol OWSCallNotificationsAdaptee <NSObject>

- (void)presentIncomingCallFromSignalId:(NSString *)signalId
                             callerName:(NSString *)callerName
    NS_SWIFT_NAME(presentIncomingCall(fromSignalId:callerName:));

@end
