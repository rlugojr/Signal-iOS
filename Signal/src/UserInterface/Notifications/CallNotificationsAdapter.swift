//  Created by Michael Kirk on 12/28/16.
//  Copyright © 2016 Open Whisper Systems. All rights reserved.

import Foundation

@objc(OWSCallNotificationsAdapter)
class CallNotificationsAdapter: NSObject {

    let TAG = "[CallNotificationsAdapter]"
    let adaptee: OWSCallNotificationsAdaptee

    override init() {
        if #available(iOS 10.0, *) {
            adaptee = UserNotificationsAdaptee()
        } else {
            adaptee = NotificationsManager()
        }
    }

    func presentIncomingCall(_ call: SignalCall, callerName: String) {
        Logger.debug("\(TAG) in \(#function)")
        adaptee.presentIncomingCall(call, callerName: callerName)
    }

    func presentMissedCall(_ call: SignalCall, callerName: String) {
        Logger.debug("\(TAG) in \(#function)")
        adaptee.presentMissedCall(call, callerName: callerName)
    }
}
