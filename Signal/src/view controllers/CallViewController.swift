//  Created by Michael Kirk on 11/10/16.
//  Copyright © 2016 Open Whisper Systems. All rights reserved.

import Foundation
import WebRTC
import PromiseKit

@objc(OWSCallRinger)
class CallRinger: NSObject {

    let vibrateRepeatDuration = 1.6
    var vibrateTimer: Timer?

    public func start() {
        vibrateTimer = Timer.scheduledTimer(timeInterval: vibrateRepeatDuration, target: self, selector: #selector(vibrate), userInfo: nil, repeats: true)
        vibrateTimer!.fire()
    }

    public func stop() {
        vibrateTimer?.invalidate()
        vibrateTimer = nil
    }

    public func vibrate() {
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
    }
}

@objc(OWSCallViewController)
class CallViewController: UIViewController {

    enum CallDirection {
        case unspecified, outgoing, incoming
    }

    let TAG = "[CallViewController]"

    // Dependencies

    let callService: CallService
    let contactsManager: OWSContactsManager
    let audioManager: AppAudioManager

    // MARK: Properties

    var peerConnectionClient: PeerConnectionClient?
    var callDirection: CallDirection = .unspecified
    var thread: TSContactThread!
    var call: SignalCall!
    let callRinger = CallRinger()

    @IBOutlet weak var contactNameLabel: UILabel!
    @IBOutlet weak var contactAvatarView: AvatarImageView!
    @IBOutlet weak var callStatusLabel: UILabel!

    // MARK: In Call Controls

    @IBOutlet weak var callControls: UIView!
    @IBOutlet weak var muteButton: UIButton!
    @IBOutlet weak var speakerPhoneButton: UIButton!

    // MARK: Incoming Call Controls
    @IBOutlet weak var incomingCallControls: UIView!

    // MARK: Initializers

    required init?(coder aDecoder: NSCoder) {
        contactsManager = Environment.getCurrent().contactsManager
        callService = Environment.getCurrent().callService
        audioManager = AppAudioManager.sharedInstance()
        super.init(coder: aDecoder)
    }

    required init() {
        contactsManager = Environment.getCurrent().contactsManager
        callService = Environment.getCurrent().callService
        audioManager = AppAudioManager.sharedInstance()
        super.init(nibName: nil, bundle: nil)
    }

    override func viewDidLoad() {

        guard let thread = self.thread else {
            Logger.error("\(TAG) tried to show call call without specifying thread.")
            showCallFailed(error: OWSErrorMakeAssertionError())
            return
        }

        contactNameLabel.text = contactsManager.displayName(forPhoneIdentifier: thread.contactIdentifier())
        contactAvatarView.image = OWSAvatarBuilder.buildImage(for: thread, contactsManager: contactsManager)

        switch callDirection {
        case .unspecified:
            Logger.error("\(TAG) must set call direction before call starts.")
            showCallFailed(error: OWSErrorMakeAssertionError())
        case .outgoing:
            // Sync to ensure we have self.call before proceeding.
            CallService.signalingQueue.sync {
                self.call = self.callService.handleOutgoingCall(thread: thread)
            }
        case .incoming:
            Logger.error("\(TAG) handling Incoming call")
            // No-op, since call service is already set up at this point, the result of which was presenting this viewController.
        }

        call.stateDidChange = updateCallStatus
        updateCallStatus(call.state)
    }

    // objc accessible way to set our swift enum.
    func setOutgoingCallDirection() {
        callDirection = .outgoing
    }

    // objc accessible way to set our swift enum.
    func setIncomingCallDirection() {
        callDirection = .incoming
    }

    func showCallFailed(error: Error) {
        // TODO Show something in UI.
        Logger.error("\(TAG) call failed with error: \(error)")
    }

    func localizedTextForCallState(_ callState: CallState) -> String {
        switch callState {
        case .idle, .remoteHangup, .localHangup:
            return NSLocalizedString("IN_CALL_TERMINATED", comment: "Call setup status label")
        case .dialing:
            return NSLocalizedString("IN_CALL_CONNECTING", comment: "Call setup status label")
        case .remoteRinging, .localRinging:
            return NSLocalizedString("IN_CALL_RINGING", comment: "Call setup status label")
        case .answering:
            return NSLocalizedString("IN_CALL_SECURING", comment: "Call setup status label")
        case .connected:
            return NSLocalizedString("IN_CALL_TALKING", comment: "Call setup status label")
        case .remoteBusy:
            return NSLocalizedString("END_CALL_RESPONDER_IS_BUSY", comment: "Call setup status label")
        case .localFailure:
            return NSLocalizedString("END_CALL_UNCATEGORIZED_FAILURE", comment: "Call setup status label")
        }
    }

    func updateCallUI(callState: CallState) {
        let textForState = localizedTextForCallState(callState)
        Logger.info("\(TAG) new call status: \(callState) aka \"\(textForState)\"")

        self.callStatusLabel.text = textForState

        // Show Ringer vs. In-Call controls.
        if callState == .localRinging {
            callRinger.start()
            callControls.isHidden = true
            incomingCallControls.isHidden = false
        } else {
            callRinger.stop()
            callControls.isHidden = false
            incomingCallControls.isHidden = true
        }

        // Dismiss Handling
        switch callState {
        case .remoteHangup, .remoteBusy, .localFailure:
            Logger.debug("\(TAG) dismissing after delay because new state is \(textForState)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.dismiss(animated: true)
            }
        case .localHangup:
            Logger.debug("\(TAG) dismissing immediately from local hangup")
            self.dismiss(animated: true)

        default: break
        }
    }

    func updateCallStatus(_ newState: CallState) {
        DispatchQueue.main.async {
            self.updateCallUI(callState: newState)
        }
    }

    // MARK: - Actions

    /**
     * Ends a connected call. Do not confuse with `didPressDenyCall`.
     */
    @IBAction func didPressHangup(sender: UIButton) {
        Logger.info("\(TAG) called \(#function)")
        if let call = self.call {
            CallService.signalingQueue.async {
                self.callService.handleLocalHungupCall(call)
            }
        }

        self.dismiss(animated: true)
    }

    @IBAction func didPressMute(sender muteButton: UIButton) {
        Logger.info("\(TAG) called \(#function)")
        muteButton.isSelected = !muteButton.isSelected
        CallService.signalingQueue.async {
            self.callService.handleToggledMute(isMuted: muteButton.isSelected)
        }
    }

    @IBAction func didPressSpeakerphone(sender speakerphoneButton: UIButton) {
        Logger.info("\(TAG) called \(#function)")
        speakerphoneButton.isSelected = !speakerphoneButton.isSelected
        audioManager.toggleSpeakerPhone(isEnabled: speakerphoneButton.isSelected)
    }

    @IBAction func didPressAnswerCall(sender: UIButton) {
        Logger.info("\(TAG) called \(#function)")

        guard let call = self.call else {
            Logger.error("\(TAG) call was unexpectedly nil. Terminating call.")
            self.callStatusLabel.text = NSLocalizedString("END_CALL_UNCATEGORIZED_FAILURE", comment: "Call setup status label")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.dismiss(animated: true)
            }
            return
        }

        CallService.signalingQueue.async {
            self.callService.handleAnswerCall(call)
        }
    }

    /**
     * Denies an incoming not-yet-connected call, Do not confuse with `didPressHangup`.
     */
    @IBAction func didPressDenyCall(sender: UIButton) {
        Logger.info("\(TAG) called \(#function)")

        // TODO handle deny separately from hangup?
        if let call = self.call {
            CallService.signalingQueue.async {
                self.callService.handleLocalHungupCall(call)
            }
        }

        self.dismiss(animated: true)
    }
}
