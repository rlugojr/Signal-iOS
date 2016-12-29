//  Created by Michael Kirk on 11/11/16.
//  Copyright © 2016 Open Whisper Systems. All rights reserved.

import Foundation
import PromiseKit
import WebRTC

/**
 * ## Call Setup (Signaling) Flow
 *
 * ## Key
 * - SS: Message sent via Signal Service
 * - DC: Message sent via WebRTC Data Channel
 *
 * |          Caller            |          Callee         |
 * +----------------------------+-------------------------+
 * handleOutgoingCall --[SS.CallOffer]-->
 * and start storing ICE updates
 *
 *                                      Received call offer
 *                                         Send call answer
 *                     <--[SS.CallAnswer]--
 *                    Start sending ICE updates immediately
 *                     <--[SS.ICEUpdates]--
 *
 * Received CallAnswer,
 * so send any stored ice updates
 *                     --[SS.ICEUpdates]-->
 *
 *     Once compatible ICE updates have been exchanged...
 *                       (ICE Connected)
 *
 * Show remote ringing UI
 *                          Connect to offered Data Channel
 *                                    Show incoming call UI.
 *
 *                                             Answers Call
 *                                   send connected message
 *                   <--[DC.ConnectedMesage]--
 * Received connected message
 * Show Call is connected.
 */

enum CallError: Error {
    case assertionError(description: String)
    case disconnected
    case externalError(underlyingError: Error)
    case timeout(description: String)
}

// FIXME TODO do we need to timeout?
fileprivate let timeoutSeconds = 60

@objc class CallService: NSObject, RTCDataChannelDelegate, RTCPeerConnectionDelegate {

    // MARK: - Properties

    let TAG = "[CallService]"

    // MARK: Dependencies

    let accountManager: AccountManager
    let messageSender: MessageSender
    var callUIAdapter: CallUIAdapter!

    // MARK: Class

    static let fallbackIceServer = RTCIceServer(urlStrings: ["stun:stun1.l.google.com:19302"])

    // Synchronize call signaling on the callSignalingQueue to make sure any appropriate requisite state is set.
    static let signalingQueue = DispatchQueue(label: "CallServiceSignalingQueue")

    // MARK: Ivars

    var peerConnectionClient: PeerConnectionClient?
    // TODO move thread into SignalCall? Or refactor messageSender to take SignalRecipient
    var thread: TSContactThread?
    var call: SignalCall?
    var sendIceUpdatesImmediately = true
    var pendingIceUpdateMessages = [OWSCallIceUpdateMessage]()
    var outgoingCallPromise: Promise<Void>?

    // Used to coordinate promises across delegate methods
    var fulfillCallConnectedPromise: (()->())?

    required init(accountManager: AccountManager, contactsManager: OWSContactsManager, messageSender: MessageSender, notificationsAdapter: CallNotificationsAdapter) {
        self.accountManager = accountManager
        self.messageSender = messageSender

        super.init()

        self.callUIAdapter = CallUIAdapter(callService: self, contactsManager: contactsManager, notificationsAdapter: notificationsAdapter)
    }

    // MARK: - Class Methods

    // MARK: Notifications

    // Wrapping these class constants in a method to make it accessible to objc
    class func callServiceActiveCallNotificationName() -> String {
        return  "CallServiceActiveCallNotification"
    }

    // MARK: - Service Actions
    // All these actions expect to be called on the SignalingQueue

    /**
     * Initiate an outgoing call.
     */
    public func handleOutgoingCall(thread: TSContactThread) -> SignalCall {
        assertOnSignalingQueue()

        self.thread = thread
        Logger.verbose("\(TAG) handling outgoing call to thread:\(thread)")

        let call = SignalCall(signalingId: UInt64.ows_random(), state: .dialing, remotePhoneNumber: thread.contactIdentifier())
        self.call = call

        sendIceUpdatesImmediately = false
        pendingIceUpdateMessages = []

        let callRecord = TSCall(timestamp: NSDate.ows_millisecondTimeStamp(), withCallNumber: call.remotePhoneNumber, callType: RPRecentCallTypeOutgoing, in: thread)
        callRecord.save()

        guard self.peerConnectionClient == nil else {
            Logger.error("\(TAG) peerconnection was unexpectedly already set.")
            call.state = .localFailure
            return call
        }

        self.callUIAdapter.startOutgoingCall(call, thread: thread)

        _ = getIceServers().then(on: CallService.signalingQueue) { iceServers -> Promise<HardenedRTCSessionDescription> in
            Logger.debug("\(self.TAG) got ice servers:\(iceServers)")
            let peerConnectionClient = PeerConnectionClient(iceServers: iceServers, peerConnectionDelegate: self)
            self.peerConnectionClient = peerConnectionClient

            // When calling, it's our responsibility to create the DataChannel. Receivers will not have to do this explicitly.
            self.peerConnectionClient!.createSignalingDataChannel(delegate: self)

            return self.peerConnectionClient!.createOffer()
        }.then(on: CallService.signalingQueue) { (sessionDescription: HardenedRTCSessionDescription) -> Promise<Void> in
            return self.peerConnectionClient!.setLocalSessionDescription(sessionDescription).then(on: CallService.signalingQueue) {
                let offerMessage = OWSCallOfferMessage(callId: call.signalingId, sessionDescription: sessionDescription.sdp)
                let callMessage = OWSOutgoingCallMessage(thread: thread, offerMessage: offerMessage)
                return self.sendMessage(callMessage)
            }
        }.catch(on: CallService.signalingQueue) { error in
            Logger.error("\(self.TAG) placing call failed with error: \(error)")

            if let callError = error as? CallError {
                self.handleFailedCall(error: callError)
            } else {
                let externalError = CallError.externalError(underlyingError: error)
                self.handleFailedCall(error: externalError)
            }
        }

        return call
    }

    /**
     * Called by the call initiator after receiving a CallAnswer from the callee.
     */
    public func handleReceivedAnswer(thread: TSContactThread, callId: UInt64, sessionDescription: String) {
        Logger.debug("\(TAG) received call answer for call: \(callId) thread: \(thread)")
        assertOnSignalingQueue()

        guard let call = self.call else {
            handleFailedCall(error: .assertionError(description:"call was unexpectedly nil in \(#function)"))
            return
        }

        guard call.signalingId == callId else {
            let description: String = "received answer for call: \(callId) but current call has id: \(call.signalingId)"
            handleFailedCall(error: .assertionError(description: description))
            return
        }

        // Now that we know the recipient trusts our identity, we no longer need to enqueue ICE updates.
        self.sendIceUpdatesImmediately = true

        if pendingIceUpdateMessages.count > 0 {
            let callMessage = OWSOutgoingCallMessage(thread: thread, iceUpdateMessages: pendingIceUpdateMessages)
            _ = sendMessage(callMessage).catch { error in
                Logger.error("\(self.TAG) failed to send ice updates in \(#function) with error: \(error)")
            }
        }

        guard let peerConnectionClient = self.peerConnectionClient else {
            handleFailedCall(error: CallError.assertionError(description: "peerConnectionClient was unexpectedly nil in \(#function)"))
            return
        }

        let sessionDescription = RTCSessionDescription(type: .answer, sdp: sessionDescription)
        _ = peerConnectionClient.setRemoteSessionDescription(sessionDescription).then {
            Logger.debug("\(self.TAG) successfully set remote description")
        }.catch(on: CallService.signalingQueue) { error in
            if let callError = error as? CallError {
                self.handleFailedCall(error: callError)
            } else {
                let externalError = CallError.externalError(underlyingError: error)
                self.handleFailedCall(error: externalError)
            }
        }
    }

    private func handleLocalBusyCall(_ call: SignalCall, thread: TSContactThread) {
        Logger.debug("\(TAG) \(#function) for call: \(call) thread: \(thread)")
        assertOnSignalingQueue()

        let busyMessage = OWSCallBusyMessage(callId: call.signalingId)
        let callMessage = OWSOutgoingCallMessage(thread: thread, busyMessage: busyMessage)
        _ = sendMessage(callMessage)

        handleMissedCall(call, thread: thread)
    }

    public func handleMissedCall(_ call: SignalCall, thread: TSContactThread) {
        // Insert missed call record
        let callRecord = TSCall(timestamp: NSDate.ows_millisecondTimeStamp(),
                                withCallNumber: thread.contactIdentifier(),
                                callType: RPRecentCallTypeMissed,
                                in: thread)
        callRecord.save()

        self.callUIAdapter.reportMissedCall(call)
    }

    public func handleRemoteBusy(thread: TSContactThread) {
        Logger.debug("\(TAG) \(#function) for thread: \(thread)")
        assertOnSignalingQueue()

        guard let call = self.call else {
            handleFailedCall(error: .assertionError(description: "call unexpectedly nil in \(#function)"))
            return
        }

        call.state = .remoteBusy
        terminateCall()
    }

    private func isBusy() -> Bool {
        // TODO CallManager adapter?
        return false
    }

    /**
     * Received an incoming call offer. We still have to complete setting up the Signaling channel before we notify
     * the user of an incoming call.
     */
    public func handleReceivedOffer(thread: TSContactThread, callId: UInt64, sessionDescription callerSessionDescription: String) {
        assertOnSignalingQueue()

        Logger.verbose("\(TAG) receivedCallOffer for thread:\(thread)")
        let newCall = SignalCall(signalingId: callId, state: .answering, remotePhoneNumber: thread.contactIdentifier())

        guard call == nil else {
            // TODO on iOS10+ we can use CallKit to swap calls rather than just returning busy immediately.
            Logger.verbose("\(TAG) receivedCallOffer for thread: \(thread) but we're already in call: \(call)")

            handleLocalBusyCall(newCall, thread: thread)
            return
        }

        self.thread = thread
        call = newCall

        let backgroundTask = UIApplication.shared.beginBackgroundTask {
            let timeout = CallError.timeout(description: "background task time ran out before call connected.")
            CallService.signalingQueue.async {
                self.handleFailedCall(error: timeout)
            }
        }

        outgoingCallPromise = firstly {
            return getIceServers()
        }.then(on: CallService.signalingQueue) { (iceServers: [RTCIceServer]) -> Promise<HardenedRTCSessionDescription> in
            // FIXME for first time call recipients I think we'll see mic/camera permission requests here,
            // even though, from the users perspective, no incoming call is yet visible.
            self.peerConnectionClient = PeerConnectionClient(iceServers: iceServers, peerConnectionDelegate: self)

            let offerSessionDescription = RTCSessionDescription(type: .offer, sdp: callerSessionDescription)
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)

            // Find a sessionDescription compatible with my constraints and the remote sessionDescription
            return self.peerConnectionClient!.negotiateSessionDescription(remoteDescription: offerSessionDescription, constraints: constraints)
        }.then(on: CallService.signalingQueue) { (negotiatedSessionDescription: HardenedRTCSessionDescription) in
            // TODO? WebRtcCallService.this.lockManager.updatePhoneState(LockManager.PhoneState.PROCESSING);
            Logger.debug("\(self.TAG) set the remote description")

            let answerMessage = OWSCallAnswerMessage(callId: newCall.signalingId, sessionDescription: negotiatedSessionDescription.sdp)
            let callAnswerMessage = OWSOutgoingCallMessage(thread: thread, answerMessage: answerMessage)

            return self.sendMessage(callAnswerMessage)
        }.then(on: CallService.signalingQueue) {
            Logger.debug("\(self.TAG) successfully sent callAnswerMessage")

            let (promise, fulfill, _) = Promise<Void>.pending()

            let timeout: Promise<Void> = after(interval: TimeInterval(timeoutSeconds)).then { () -> Void in
                // rejecting a promise by throwing is safely a no-op if the promise has already been fulfilled
                throw CallError.timeout(description: "timed out waiting for call to connect")
            }

            // This will be fulfilled (potentially) by the RTCDataChannel delegate method
            self.fulfillCallConnectedPromise = fulfill

            return race(promise, timeout)
        }.catch(on: CallService.signalingQueue) { error in
            if let callError = error as? CallError {
                self.handleFailedCall(error: callError)
            } else {
                let externalError = CallError.externalError(underlyingError: error)
                self.handleFailedCall(error: externalError)
            }
        }.always {
            Logger.debug("\(self.TAG) ending background task awaiting inbound call connection")
            UIApplication.shared.endBackgroundTask(backgroundTask)
        }
    }

    public func handleCallBack(recipientId: String) {
        guard self.call == nil else {
            Logger.error("\(TAG) unexpectedly found an existing call when trying to call back: \(recipientId)")
            return
        }

        let thread = TSContactThread.getOrCreateThread(contactId: recipientId)
        let call = handleOutgoingCall(thread: thread)

        self.callUIAdapter.showCall(call)
    }

    public func handleRemoteAddedIceCandidate(thread: TSContactThread, callId: UInt64, sdp: String, lineIndex: Int32, mid: String) {
        assertOnSignalingQueue()
        Logger.debug("\(TAG) called \(#function)")

        guard self.thread != nil else {
            handleFailedCall(error: .assertionError(description: "ignoring remote ice update for thread: \(thread.uniqueId) since there is no current thread. TODO: Signaling messages out of order?"))
            return
        }

        guard thread.contactIdentifier() == self.thread!.contactIdentifier() else {
            handleFailedCall(error: .assertionError(description: "ignoring remote ice update for thread: \(thread.uniqueId) since the current call is for thread: \(self.thread!.uniqueId)"))
            return
        }

        guard let call = self.call else {
            handleFailedCall(error: .assertionError(description: "ignoring remote ice update for callId: \(callId), since there is no current call."))
            return
        }

        guard call.signalingId == callId else {
            handleFailedCall(error: .assertionError(description: "ignoring remote ice update for call: \(callId) since the current call is: \(call.signalingId)"))
            return
        }

        guard let peerConnectionClient = self.peerConnectionClient else {
            handleFailedCall(error: .assertionError(description: "ignoring remote ice update for thread: \(thread) since the current call hasn't initialized it's peerConnectionClient"))
            return
        }

        peerConnectionClient.addIceCandidate(RTCIceCandidate(sdp: sdp, sdpMLineIndex: lineIndex, sdpMid: mid))
    }

    private func handleLocalAddedIceCandidate(_ iceCandidate: RTCIceCandidate) {
        assertOnSignalingQueue()

        guard let call = self.call else {
            handleFailedCall(error: .assertionError(description: "ignoring local ice candidate, since there is no current call."))
            return
        }

        guard call.state != .idle else {
            handleFailedCall(error: .assertionError(description: "ignoring local ice candidate, since call is now idle."))
            return
        }

        guard let thread = self.thread else {
            handleFailedCall(error: .assertionError(description: "ignoring local ice candidate, because there was no current TSContactThread."))
            return
        }

        let iceUpdateMessage = OWSCallIceUpdateMessage(callId: call.signalingId, sdp: iceCandidate.sdp, sdpMLineIndex: iceCandidate.sdpMLineIndex, sdpMid: iceCandidate.sdpMid)

        if self.sendIceUpdatesImmediately {
            let callMessage = OWSOutgoingCallMessage(thread: thread, iceUpdateMessage: iceUpdateMessage)
            _ = sendMessage(callMessage)
        } else {
            // For outgoing messages, we wait to send ice updates until we're sure client received our call message.
            // e.g. if the client has blocked our message due to an identity change, we'd otherwise
            // bombard them with a bunch *more* undecipherable messages.
            Logger.debug("\(TAG) enqueuing iceUpdate until we receive call answer")
            self.pendingIceUpdateMessages.append(iceUpdateMessage)
            return
        }
    }

    private func handleIceConnected() {
        assertOnSignalingQueue()

        Logger.debug("\(TAG) in \(#function)")

        guard let call = self.call else {
            handleFailedCall(error: .assertionError(description:"\(TAG) ignoring \(#function) since there is no current call."))
            return
        }

        guard let thread = self.thread else {
            handleFailedCall(error: .assertionError(description:"\(TAG) ignoring \(#function) since there is no current thread."))
            return
        }

        guard let peerConnectionClient = self.peerConnectionClient else {
            handleFailedCall(error: .assertionError(description:"\(TAG) ignoring \(#function) since there is no current peerConnectionClient."))
            return
        }

        switch call.state {
        case .dialing:
            call.state = .remoteRinging
        case .answering:
            call.state = .localRinging
            self.callUIAdapter.reportIncomingCall(call, thread: thread, audioManager: peerConnectionClient)
            self.fulfillCallConnectedPromise?()
        case .remoteRinging:
            Logger.info("\(TAG) call alreading ringing. Ignoring \(#function)")
        default:
            Logger.debug("\(TAG) unexpected call state for \(#function): \(call.state)")
        }
    }

    public func handleRemoteHangup(thread: TSContactThread) {
        Logger.debug("\(TAG) in \(#function)")
        assertOnSignalingQueue()

        guard thread.contactIdentifier() == self.thread?.contactIdentifier() else {
            // This can safely be ignored. 
            // We don't want to fail the current call because an old call was slow to send us the hangup message.
            Logger.warn("\(TAG) ignoring hangup for thread:\(thread) which is not the current thread: \(self.thread)")
            return
        }

        guard let call = self.call else {
            handleFailedCall(error: .assertionError(description:"\(TAG) call was unexpectedly nil in \(#function)"))
            return
        }

        switch call.state {
        case .idle, .dialing, .answering, .localRinging, .localFailure, .remoteBusy, .remoteRinging:
            handleMissedCall(call, thread: thread)
        case .connected, .localHangup, .remoteHangup:
            Logger.info("\(TAG) call is finished.")
        }

        call.state = .remoteHangup
        callUIAdapter.endCall(call)

        // self.call is nil'd in `terminateCall`, so it's important we update it's state *before* calling `terminateCall`
        terminateCall()
    }

    public func handleAnswerCall(localId: UUID) {
        // #function is called from objc, how to access swift defiend dispatch queue (OS_dispatch_queue)
        //assertOnSignalingQueue()

        guard let call = self.call else {
            handleFailedCall(error: .assertionError(description:"\(TAG) call was unexpectedly nil in \(#function)"))
            return
        }

        guard call.localId == localId else {
            handleFailedCall(error: .assertionError(description:"\(TAG) callLocalId:\(localId) doesn't match current calls: \(call.localId)"))
            return
        }

        // Because we may not be on signalingQueue (because this method is called from Objc which doesn't have 
        // access to signalingQueue (that I can find). FIXME?
        type(of: self).signalingQueue.async {
            self.handleAnswerCall(call)
        }
    }

    public func handleAnswerCall(_ call: SignalCall) {
        assertOnSignalingQueue()

        Logger.debug("\(TAG) in \(#function)")

        guard self.call != nil else {
            handleFailedCall(error: .assertionError(description:"\(TAG) ignoring \(#function) since there is no current call"))
            return
        }

        guard call == self.call! else {
            // This could conceivably happen if the other party of an old call was slow to send us their answer
            // and we've subsequently engaged in another call. Don't kill the current call, but just ignore it.
            Logger.warn("\(TAG) ignoring \(#function) for call other than current call")
            return
        }

        guard let thread = self.thread else {
            handleFailedCall(error: .assertionError(description:"\(TAG) ignoring \(#function) for call other than current call"))
            return
        }

        guard let peerConnectionClient = self.peerConnectionClient else {
            handleFailedCall(error: .assertionError(description:"\(TAG) missing peerconnection client in \(#function)"))
            return
        }

        let callRecord = TSCall(timestamp: NSDate.ows_millisecondTimeStamp(), withCallNumber: call.remotePhoneNumber, callType: RPRecentCallTypeIncoming, in: thread)
        callRecord.save()

        callUIAdapter.answerCall(call)

        let message = DataChannelMessage.forConnected(callId: call.signalingId)
        if peerConnectionClient.sendDataChannelMessage(data: message.asData()) {
            Logger.debug("\(TAG) sendDataChannelMessage returned true")
        } else {
            Logger.warn("\(TAG) sendDataChannelMessage returned false")
        }

        handleConnectedCall(call)
    }

    func handleConnectedCall(_ call: SignalCall) {
        Logger.debug("\(TAG) in \(#function)")
        assertOnSignalingQueue()

        guard let peerConnectionClient = self.peerConnectionClient else {
            handleFailedCall(error: .assertionError(description:"\(TAG) peerConnectionClient unexpectedly nil in \(#function)"))
            return
        }

        call.state = .connected

        // We don't risk transmitting any media until the remote client has admitted to being connected.
        peerConnectionClient.setAudioEnabled(enabled: true)
        peerConnectionClient.setVideoEnabled(enabled: call.hasVideo)
    }

    public func handleDeclineCall(localId: UUID) {
        // #function is called from objc, how to access swift defiend dispatch queue (OS_dispatch_queue)
        //assertOnSignalingQueue()

        guard let call = self.call else {
            handleFailedCall(error: .assertionError(description:"\(TAG) call was unexpectedly nil in \(#function)"))
            return
        }

        guard call.localId == localId else {
            handleFailedCall(error: .assertionError(description:"\(TAG) callLocalId:\(localId) doesn't match current calls: \(call.localId)"))
            return
        }

        // Because we may not be on signalingQueue (because this method is called from Objc which doesn't have
        // access to signalingQueue (that I can find). FIXME?
        type(of: self).signalingQueue.async {
            self.handleDeclineCall(call)
        }
    }

    public func handleDeclineCall(_ call: SignalCall) {
        assertOnSignalingQueue()

        Logger.info("\(TAG) in \(#function)")

        // Currently we just handle this as a hangup. But we could offer more descriptive action. e.g. DataChannel message
        handleLocalHungupCall(call)
    }

    func handleLocalHungupCall(_ call: SignalCall) {
        assertOnSignalingQueue()

        guard self.call != nil else {
            handleFailedCall(error: .assertionError(description:"\(TAG) ignoring \(#function) since there is no current call"))
            return
        }

        guard call == self.call! else {
            handleFailedCall(error: .assertionError(description:"\(TAG) ignoring \(#function) for call other than current call"))
            return
        }

        guard let peerConnectionClient = self.peerConnectionClient else {
            handleFailedCall(error: .assertionError(description:"\(TAG) missing peerconnection client in \(#function)"))
            return
        }

        guard let thread = self.thread else {
            handleFailedCall(error: .assertionError(description:"\(TAG) missing thread in \(#function)"))
            return
        }

        call.state = .localHangup
        callUIAdapter.endCall(call)

        // TODO something like this lifted from Signal-Android.
        //        this.accountManager.cancelInFlightRequests();
        //        this.messageSender.cancelInFlightRequests();

        // If the call is connected, we can send the hangup via the data channel.
        let message = DataChannelMessage.forHangup(callId: call.signalingId)
        if peerConnectionClient.sendDataChannelMessage(data: message.asData()) {
            Logger.debug("\(TAG) sendDataChannelMessage returned true")
        } else {
            Logger.warn("\(TAG) sendDataChannelMessage returned false")
        }

        // If the call hasn't started yet, we don't have a data channel to communicate the hang up. Use Signal Service Message.
        let hangupMessage = OWSCallHangupMessage(callId: call.signalingId)
        let callMessage = OWSOutgoingCallMessage(thread: thread, hangupMessage: hangupMessage)
        _  = sendMessage(callMessage).then(on: CallService.signalingQueue) {
            Logger.debug("\(self.TAG) successfully sent hangup call message to \(thread)")
        }.catch(on: CallService.signalingQueue) { error in
            Logger.error("\(self.TAG) failed to send hangup call message to \(thread) with error: \(error)")
        }

        terminateCall()
    }

    func handleToggledMute(isMuted: Bool) {
        assertOnSignalingQueue()

        guard let peerConnectionClient = self.peerConnectionClient else {
            handleFailedCall(error: .assertionError(description:"\(TAG) peerConnectionClient unexpectedly nil in \(#function)"))
            return
        }
        peerConnectionClient.setAudioEnabled(enabled: !isMuted)
    }

    private func handleDataChannelMessage(_ message: OWSWebRTCProtosData) {
        assertOnSignalingQueue()

        guard let call = self.call else {
            handleFailedCall(error: .assertionError(description:"\(TAG) received data message, but there is no current call. Ignoring."))
            return
        }

        if message.hasConnected() {
            Logger.debug("\(TAG) remote participant sent Connected via data channel")

            let connected = message.connected!

            guard connected.id == call.signalingId else {
                handleFailedCall(error: .assertionError(description:"\(TAG) received connected message for call with id:\(connected.id) but current call has id:\(call.signalingId)"))
                return
            }

            handleConnectedCall(call)

        } else if message.hasHangup() {
            Logger.debug("\(TAG) remote participant sent Hangup via data channel")

            let hangup = message.hangup!

            guard hangup.id == call.signalingId else {
                handleFailedCall(error: .assertionError(description:"\(TAG) received hangup message for call with id:\(hangup.id) but current call has id:\(call.signalingId)"))
                return
            }

            guard let thread = self.thread else {
                handleFailedCall(error: .assertionError(description:"\(TAG) current contact thread is unexpectedly nil when receiving hangup DataChannelMessage"))
                return
            }

            handleRemoteHangup(thread: thread)
        } else if message.hasVideoStreamingStatus() {
            Logger.debug("\(TAG) remote participant sent VideoStreamingStatus via data channel")

            // TODO: translate from java
            //   Intent intent = new Intent(this, WebRtcCallService.class);
            //   intent.setAction(ACTION_REMOTE_VIDEO_MUTE);
            //   intent.putExtra(EXTRA_CALL_ID, dataMessage.getVideoStreamingStatus().getId());
            //   intent.putExtra(EXTRA_MUTE, !dataMessage.getVideoStreamingStatus().getEnabled());
            //   startService(intent);
        }
    }

    // MARK: Helpers

    private func assertOnSignalingQueue() {
        if #available(iOS 10.0, *) {
            dispatchPrecondition(condition: .onQueue(type(of: self).signalingQueue))
        } else {
            // Skipping check on <iOS10, since syntax is different and it's just a development convenience.
        }
    }

    fileprivate func getIceServers() -> Promise<[RTCIceServer]> {

        return firstly {
            return accountManager.getTurnServerInfo()
        }.then(on: CallService.signalingQueue) { turnServerInfo -> [RTCIceServer] in
            Logger.debug("\(self.TAG) got turn server urls: \(turnServerInfo.urls)")

            return turnServerInfo.urls.map { url in
                if url.hasPrefix("turn") {
                    // only pass credentials for "turn:" servers.
                    return RTCIceServer(urlStrings: [url], username: turnServerInfo.username, credential: turnServerInfo.password)
                } else {
                    return RTCIceServer(urlStrings: [url])
                }
            } + [CallService.fallbackIceServer]
        }
    }

    fileprivate func sendMessage(_ message: OWSOutgoingCallMessage) -> Promise<Void> {
        return Promise { fulfill, reject in
            self.messageSender.send(message, success: fulfill, failure: reject)
        }
    }

    private func handleFailedCall(error: CallError) {
        assertOnSignalingQueue()
        Logger.error("\(TAG) call failed with error: \(error)")

        // It's essential to set call.state before terminateCall, because terminateCall nils self.call
        call?.error = error
        call?.state = .localFailure

        terminateCall()
    }

    private func terminateCall() {
        assertOnSignalingQueue()

//        lockManager.updatePhoneState(LockManager.PhoneState.PROCESSING);
//        NotificationBarManager.setCallEnded(this);
//
//        incomingRinger.stop();
//        outgoingRinger.stop();
//        outgoingRinger.playDisconnected();
//
//        if (peerConnection != null) {
//            peerConnection.dispose();
//            peerConnection = null;
//        }
//
//        if (eglBase != null && localRenderer != null && remoteRenderer != null) {
//            localRenderer.release();
//            remoteRenderer.release();
//            eglBase.release();
//        }
//
//        shutdownAudio();
//
//        this.callState         = CallState.STATE_IDLE;
//        this.recipient         = null;
//        this.callId            = null;
//        this.audioEnabled      = false;
//        this.videoEnabled      = false;
//        this.pendingIceUpdates = null;
//        lockManager.updatePhoneState(LockManager.PhoneState.IDLE);

        peerConnectionClient?.terminate()
        peerConnectionClient = nil
        call = nil
        thread = nil
        outgoingCallPromise = nil
        sendIceUpdatesImmediately = true
        pendingIceUpdateMessages = []
    }

    // MARK: - RTCDataChannelDelegate

    /** The data channel state changed. */
    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        Logger.debug("\(TAG) dataChannelDidChangeState: \(dataChannel)")
        // SignalingQueue.dispatch.async {}
    }

    /** The data channel successfully received a data buffer. */
    public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        Logger.debug("\(TAG) dataChannel didReceiveMessageWith buffer:\(buffer)")

        guard let dataChannelMessage = OWSWebRTCProtosData.parse(from:buffer.data) else {
            // TODO can't proto parsings throw an exception? Is it just being lost in the Objc->Swift?
            Logger.error("\(TAG) failed to parse dataProto")
            return
        }

        CallService.signalingQueue.async {
            self.handleDataChannelMessage(dataChannelMessage)
        }
    }

    /** The data channel's |bufferedAmount| changed. */
    public func dataChannel(_ dataChannel: RTCDataChannel, didChangeBufferedAmount amount: UInt64) {
        Logger.debug("\(TAG) didChangeBufferedAmount: \(amount)")
    }

    // MARK: - RTCPeerConnectionDelegate

    /** Called when the SignalingState changed. */
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        Logger.debug("\(TAG) didChange signalingState:\(stateChanged.debugDescription)")
    }

    /** Called when media is received on a new stream from remote peer. */
    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        Logger.debug("\(TAG) didAdd stream:\(stream)")
    }

    /** Called when a remote peer closes a stream. */
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        Logger.debug("\(TAG) didRemove Stream:\(stream)")
    }

    /** Called when negotiation is needed, for example ICE has restarted. */
    public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        Logger.debug("\(TAG) shouldNegotiate")
    }

    /** Called any time the IceConnectionState changes. */
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Logger.debug("\(TAG) didChange IceConnectionState:\(newState.debugDescription)")

        CallService.signalingQueue.async {
            switch newState {
            case .connected, .completed:
                self.handleIceConnected()
            case .failed:
                Logger.warn("\(self.TAG) RTCIceConnection failed.")
                guard let thread = self.thread else {
                    Logger.error("\(self.TAG) refusing to hangup for failed IceConnection because there is no current thread")
                    return
                }
                self.handleFailedCall(error: CallError.disconnected)
            default:
                Logger.debug("\(self.TAG) ignoring change IceConnectionState:\(newState.debugDescription)")
            }
        }
    }

    /** Called any time the IceGatheringState changes. */
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        Logger.debug("\(TAG) didChange IceGatheringState:\(newState.debugDescription)")
    }

    /** New ice candidate has been found. */
    public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Logger.debug("\(TAG) didGenerate IceCandidate:\(candidate.sdp)")
        CallService.signalingQueue.async {
            self.handleLocalAddedIceCandidate(candidate)
        }
    }

    /** Called when a group of local Ice candidates have been removed. */
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        Logger.debug("\(TAG) didRemove IceCandidates:\(candidates)")
    }

    /** New data channel has been opened. */
    public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        Logger.debug("\(TAG) didOpen dataChannel:\(dataChannel)")
        CallService.signalingQueue.async {
            guard let peerConnectionClient = self.peerConnectionClient else {
                Logger.error("\(self.TAG) surprised to find nil peerConnectionClient in \(#function)")
                return
            }

            Logger.debug("\(self.TAG) set dataChannel")
            peerConnectionClient.dataChannel = dataChannel
        }
    }
}

fileprivate extension UInt64 {
    static func ows_random() -> UInt64 {
        var random: UInt64 = 0
        arc4random_buf(&random, MemoryLayout.size(ofValue: random))
        return random
    }
}

// Mark: Pretty Print Objc enums.

fileprivate extension RTCSignalingState {
    var debugDescription: String {
        switch self {
        case .stable:
            return "stable"
        case .haveLocalOffer:
            return "haveLocalOffer"
        case .haveLocalPrAnswer:
            return "haveLocalPrAnswer"
        case .haveRemoteOffer:
            return "haveRemoteOffer"
        case .haveRemotePrAnswer:
            return "haveRemotePrAnswer"
        case .closed:
            return "closed"
        }
    }
}

fileprivate extension RTCIceGatheringState {
    var debugDescription: String {
        switch self {
        case .new:
            return "new"
        case .gathering:
            return "gathering"
        case .complete:
            return "complete"
        }
    }
}

fileprivate extension RTCIceConnectionState {
    var debugDescription: String {
        switch self {
        case .new:
            return "new"
        case .checking:
            return "checking"
        case .connected:
            return "connected"
        case .completed:
            return "completed"
        case .failed:
            return "failed"
        case .disconnected:
            return "disconnected"
        case .closed:
            return "closed"
        case .count:
            return "count"
        }
    }
}
