//  Created by Frederic Jacobs on 22/12/15.
//  Copyright © 2015 Open Whisper Systems. All rights reserved.

#import <SignalServiceKit/NotificationsProtocol.h>

NS_ASSUME_NONNULL_BEGIN

@class TSCall;
@class TSContactThread;
@class OWSContactsManager;
@class OWSSignalCall;
@class PropertyListPreferences;

@interface NotificationsManager : NSObject <NotificationsProtocol>

- (instancetype)initWithContactsManager:(OWSContactsManager *)contactsManager
                            preferences:(PropertyListPreferences *)preferences NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

- (void)notifyUserForCall:(TSCall *)call inThread:(TSThread *)thread;
- (void)incomingCallFromSignalId:(NSString *)signalId NS_SWIFT_NAME(incomingCall(fromSignalId:));
//- (void)missedCall:(OWSSignalCall *)call thread:(TSContactThread *)thread;

@end

NS_ASSUME_NONNULL_END
