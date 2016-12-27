//  Created by Michael Kirk on 12/13/16.
//  Copyright © 2016 Open Whisper Systems. All rights reserved.

import Foundation
import PromiseKit
import CallKit

protocol CallUIAdaptee {
    func startOutgoingCall(_ call: SignalCall)
    func reportIncomingCall(_ call: SignalCall, audioManager: CallAudioManager)
    func answerCall(_ call: SignalCall)
    func endCall(_ call: SignalCall)
}

/**
 * Manage call related UI in a pre-CallKit world.
 */
class CallUIiOS8Adaptee: CallUIAdaptee {

    let TAG = "[CallUIiOS8Adaptee]"

    let notificationsManager: NotificationsManager

    required init(notificationsManager: NotificationsManager) {
        self.notificationsManager = notificationsManager
    }

    func startOutgoingCall(_ call: SignalCall) {
        Logger.error("\(TAG) TODO \(#function)")
    }

    func reportIncomingCall(_ call: SignalCall, audioManager: CallAudioManager) {
        Logger.debug("\(TAG) \(#function)")

        // present Call View controller
        let callNotificationName = CallService.callServiceActiveCallNotificationName()
        NotificationCenter.default.post(name: NSNotification.Name(rawValue: callNotificationName), object: call)
    
        if UIApplication.shared.applicationState != .active {
            notificationsManager.incomingCall(fromSignalId: call.remotePhoneNumber)
        }
    }

    func answerCall(_ call: SignalCall) {
        // NO-OP
    }

    func endCall(_ call: SignalCall) {
        // NO-OP
    }
}

@available(iOS 10.0, *)
class CallUICallKitAdaptee: CallUIAdaptee {

    let TAG = "[CallUICallKitAdaptee]"
    let providerDelegate: ProviderDelegate
    let callManager: SpeakerboxCallManager

    init(callService: CallService) {
        callManager = SpeakerboxCallManager()
        providerDelegate = ProviderDelegate(callManager: callManager, callService: callService)
    }

    func startOutgoingCall(_ call: SignalCall) {
        providerDelegate.callManager.startCall(handle: call.remotePhoneNumber, video: call.hasVideo)
    }

    func reportIncomingCall(_ call: SignalCall, audioManager: CallAudioManager) {
        // FIXME weird to pass the audio manager in here.
        // Crux is, the peerconnectionclient is what controls the audio channel.
        // But a peerconnectionclient is per call.
        // While this providerDelegate is an app singleton.
        providerDelegate.audioManager = audioManager
        providerDelegate.reportIncomingCall(call) { error in
            if error == nil {
                Logger.debug("\(self.TAG) successfully reported incoming call.")
            } else {
                Logger.error("\(self.TAG) providerDelegate.reportIncomingCall failed with error: \(error)")
            }
        }
    }

    func answerCall(_ call: SignalCall) {
        let callNotificationName = CallService.callServiceActiveCallNotificationName()
        NotificationCenter.default.post(name: NSNotification.Name(rawValue: callNotificationName), object: call)
    }

    func endCall(_ call: SignalCall) {
        callManager.end(call: call)
    }
}

class CallUIAdapter {

    let TAG = "[CallUIAdapter]"
    let adaptee: CallUIAdaptee

    init(notificationsManager: NotificationsManager, callService: CallService) {
        if Platform.isSimulator {
            // Callkit doesn't seem entirely supported in simulator.
            // e.g. you can't receive calls in the call screen.
            Logger.info("\(TAG) choosing non-callkit adaptee for simulator.")
            adaptee = CallUIiOS8Adaptee(notificationsManager: notificationsManager)
        } else if #available(iOS 10.0, *) {
            Logger.info("\(TAG) choosing callkit adaptee for iOS10+")
            adaptee = CallUICallKitAdaptee(callService: callService)
        } else {
            Logger.info("\(TAG) choosing non-callkit adaptee for older iOS")
            adaptee = CallUIiOS8Adaptee(notificationsManager: notificationsManager)
        }
    }

    func reportIncomingCall(_ call: SignalCall, thread: TSContactThread, audioManager: CallAudioManager) {
        adaptee.reportIncomingCall(call, audioManager: audioManager)
    }

    func startOutgoingCall(_ call: SignalCall, thread: TSContactThread) {
        adaptee.startOutgoingCall(call)
    }

    func answerCall(_ call: SignalCall) {
        adaptee.answerCall(call)
    }

    func endCall(_ call: SignalCall) {
        adaptee.endCall(call)
    }
}

/**
 * I actually don't yet understand the role of these CallAudioManager methods as
 * called in the speakerbox example. Are they redundant with what the RTC setup
 * already does for us?
 *
 * Here's the AVSessionConfig for the ARDRTC Example app, which maybe belongs
 * in the coonfigureAudio session. and maybe the adding audio tracks is sufficient for startAudio's implenetation?
 *
 *
 187   RTCAudioSessionConfiguration *configuration =
 188       [[RTCAudioSessionConfiguration alloc] init];
 189   configuration.category = AVAudioSessionCategoryAmbient;
 190   configuration.categoryOptions = AVAudioSessionCategoryOptionDuckOthers;
 191   configuration.mode = AVAudioSessionModeDefault;
 192
 193   RTCAudioSession *session = [RTCAudioSession sharedInstance];
 194   [session lockForConfiguration];
 195   BOOL hasSucceeded = NO;
 196   NSError *error = nil;
 197   if (session.isActive) {
 198     hasSucceeded = [session setConfiguration:configuration error:&error];
 199   } else {
 200     hasSucceeded = [session setConfiguration:configuration
 201                                       active:YES
 202                                        error:&error];
 203   }
 204   if (!hasSucceeded) {
 205     RTCLogError(@"Error setting configuration: %@", error.localizedDescription);
 206   }
 207   [session unlockForConfiguration];
 */
protocol CallAudioManager {
    func startAudio()
    func stopAudio()
    func configureAudioSession()
}
