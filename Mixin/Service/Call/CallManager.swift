import Foundation
import WebRTC
import MixinServices

class CallManager {
    
    typealias PendingOffer = (call: Call, sdp: RTCSessionDescription)
    
    static let shared = CallManager()
    static let usesCallKit = true
    
    let ringtonePlayer = try? AVAudioPlayer(contentsOf: Bundle.main.url(forResource: "call", withExtension: "caf")!)
    
    private(set) var call: Call?
    private(set) var pendingOffers = [UUID: PendingOffer]()
    
    var isMuted = false {
        didSet {
            guard rtcClient.iceConnectionState == .connected else {
                return
            }
            rtcClient.isMuted = isMuted
        }
    }
    
    var usesSpeaker = false {
        didSet {
            guard rtcClient.iceConnectionState == .connected else {
                return
            }
            queue.async {
                try? AVAudioSession.sharedInstance().overrideOutputAudioPort(self.port)
            }
        }
    }
    
    private let queue = DispatchQueue(label: "one.mixin.messenger.call-manager")
    
    private lazy var rtcClient = WebRTCClient()
    private lazy var vibrator = Vibrator()
    private lazy var nativeCallInterface = NativeCallInterface(manager: self)
    private lazy var mixinCallInterface = MixinCallInterface(manager: self)
    
    private var window: CallWindow?
    private var viewController: CallViewController?
    private var pendingCandidates = [UUID: [RTCIceCandidate]]()
    
    private weak var unansweredTimer: Timer?
    
    private var callInterface: CallInterface {
        if Self.usesCallKit && AVAudioSession.sharedInstance().recordPermission == .granted {
            return nativeCallInterface
        } else {
            return mixinCallInterface
        }
    }
    
    private var port: AVAudioSession.PortOverride {
        usesSpeaker ? .speaker : .none
    }
    
    init() {
        RTCAudioSession.sharedInstance().useManualAudio = true
        rtcClient.delegate = self
        ringtonePlayer?.numberOfLoops = -1
        NotificationCenter.default.addObserver(self, selector: #selector(audioSessionRouteChange(_:)), name: AVAudioSession.routeChangeNotification, object: nil)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    func showCallingInterface(user: UserItem, style: CallViewController.Style) {
        let animated = self.window != nil
        
        let viewController = self.viewController ?? CallViewController()
        viewController.manager = self
        viewController.loadViewIfNeeded()
        viewController.reload(user: user)
        self.viewController = viewController
        
        let window = self.window ?? CallWindow(frame: UIScreen.main.bounds)
        window.rootViewController = viewController
        window.makeKeyAndVisible()
        self.window = window
        
        UIView.performWithoutAnimation(viewController.view.layoutIfNeeded)
        
        let updateInterface = {
            viewController.style = style
            viewController.view.layoutIfNeeded()
        }
        if animated {
            UIView.animate(withDuration: 0.3, animations: updateInterface)
        } else {
            UIView.performWithoutAnimation(updateInterface)
        }
    }
    
    func dismissCallingInterface() {
        AppDelegate.current.mainWindow.makeKeyAndVisible()
        viewController?.disableConnectionDurationTimer()
        viewController = nil
        window = nil
    }
    
}

// MARK: - Interface
extension CallManager {
    
    func handlePendingWebRTCJobs() {
        queue.async {
            let jobs = JobDAO.shared.nextBatchJobs(category: .Task, action: .PENDING_WEBRTC, limit: nil)
            for job in jobs {
                let data = job.toBlazeMessageData()
                let isOffer = data.category == MessageCategory.WEBRTC_AUDIO_OFFER.rawValue
                let isTimedOut = abs(data.createdAt.toUTCDate().timeIntervalSinceNow) >= callTimeoutInterval
                if isOffer && isTimedOut {
                    let msg = Message.createWebRTCMessage(messageId: data.messageId,
                                                          conversationId: data.conversationId,
                                                          userId: data.userId,
                                                          category: .WEBRTC_AUDIO_CANCEL,
                                                          mediaDuration: 0,
                                                          status: .DELIVERED)
                    MessageDAO.shared.insertMessage(message: msg, messageSource: "")
                } else if !isOffer || !MessageDAO.shared.isExist(messageId: data.messageId) {
                    self.handleIncomingBlazeMessageData(data)
                }
                JobDAO.shared.removeJob(jobId: job.jobId)
            }
        }
    }
    
    func requestStartCall(opponentUser: UserItem) {
        let uuid = UUID()
        do {
            try AVAudioSession.sharedInstance().overrideOutputAudioPort(.none)
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat)
        } catch {
            reporter.report(error: error)
        }
        callInterface.requestStartCall(uuid: uuid, handle: .userId(opponentUser.userId)) { (error) in
            if let error = error as? CallError {
                self.alert(error: error)
            } else if let error = error {
                print(error)
            }
        }
    }
    
    func requestEndCall() {
        guard let uuid = call?.uuid ?? pendingOffers.first?.key else {
            return
        }
        callInterface.requestEndCall(uuid: uuid) { (error) in
            if let error = error {
                // Don't think we would get error here
                reporter.report(error: error)
                self.endCall(uuid: uuid)
            }
        }
    }
    
    func requestAnswerCall() {
        guard let uuid = pendingOffers.first?.key else {
            return
        }
        answerCall(uuid: uuid, completion: nil)
    }
    
    func requestSetMute(_ muted: Bool) {
        guard let uuid = call?.uuid else {
            return
        }
        callInterface.requestSetMute(uuid: uuid, muted: muted) { (error) in
            if let error = error {
                reporter.report(error: error)
            }
        }
    }
    
    func alert(error: CallError) {
        guard let content = error.alertContent else {
            return
        }
        DispatchQueue.main.async {
            if case .microphonePermissionDenied = error {
                AppDelegate.current.mainWindow.rootViewController?.alertSettings(content)
            } else {
                AppDelegate.current.mainWindow.rootViewController?.alert(content)
            }
        }
    }
    
}

// MARK: - Callback
extension CallManager {
    
    func startCall(uuid: UUID, handle: CallHandle, completion: ((Bool) -> Void)?) {
        AudioManager.shared.pause()
        queue.async {
            guard case let .userId(userId) = handle else {
                self.alert(error: .invalidHandle)
                completion?(false)
                return
            }
            guard let opponentUser = UserDAO.shared.getUser(userId: userId) else {
                self.alert(error: .invalidHandle)
                completion?(false)
                return
            }
            guard WebSocketService.shared.isConnected else {
                self.alert(error: .networkFailure)
                completion?(false)
                return
            }
            DispatchQueue.main.sync {
                self.showCallingInterface(user: opponentUser, style: .outgoing)
            }
            let call = Call(uuid: uuid, opponentUser: opponentUser, isOutgoing: true)
            self.call = call
            
            let timer = Timer(timeInterval: callTimeoutInterval,
                              target: self,
                              selector: #selector(self.unansweredTimeout),
                              userInfo: nil,
                              repeats: false)
            RunLoop.main.add(timer, forMode: .default)
            self.unansweredTimer = timer
            
            let conversationId = call.conversationId
            self.rtcClient.offer { (sdp, error) in
                guard let sdp = sdp else {
                    self.queue.async {
                        self.failCurrentCall(sendFailedMessageToRemote: false,
                                             error: .sdpConstruction(error))
                        completion?(false)
                    }
                    return
                }
                guard let content = sdp.jsonString else {
                    self.queue.async {
                        self.failCurrentCall(sendFailedMessageToRemote: false,
                                             error: .sdpSerialization(error))
                        completion?(false)
                    }
                    return
                }
                let msg = Message.createWebRTCMessage(messageId: call.uuidString,
                                                      conversationId: conversationId,
                                                      category: .WEBRTC_AUDIO_OFFER,
                                                      content: content,
                                                      status: .SENDING)
                SendMessageService.shared.sendMessage(message: msg, ownerUser: opponentUser, isGroupMessage: false)
                completion?(true)
            }
        }
    }
    
    func answerCall(uuid: UUID, completion: ((Bool) -> Void)?) {
        queue.async {
            guard let (call, offer) = self.pendingOffers.removeValue(forKey: uuid) else {
                return
            }
            self.call = call // TODO: Fail other pending calls
            self.ringtonePlayer?.stop()
            self.rtcClient.set(remoteSdp: offer) { (error) in
                if let error = error {
                    self.queue.async {
                        self.failCurrentCall(sendFailedMessageToRemote: true,
                                             error: .setRemoteSdp(error))
                        completion?(false)
                    }
                } else {
                    self.rtcClient.answer(completion: { (answer, error) in
                        self.queue.async {
                            guard let answer = answer, let content = answer.jsonString else {
                                self.failCurrentCall(sendFailedMessageToRemote: true,
                                                     error: .answerConstruction(error))
                                completion?(false)
                                return
                            }
                            let msg = Message.createWebRTCMessage(conversationId: call.conversationId,
                                                                  category: .WEBRTC_AUDIO_ANSWER,
                                                                  content: content,
                                                                  status: .SENDING,
                                                                  quoteMessageId: call.uuidString)
                            SendMessageService.shared.sendMessage(message: msg,
                                                                  ownerUser: call.opponentUser,
                                                                  isGroupMessage: false)
                            if let candidates = self.pendingCandidates[uuid] {
                                candidates.forEach(self.rtcClient.add(remoteCandidate:))
                            }
                            DispatchQueue.main.sync {
                                self.showCallingInterface(user: call.opponentUser, style: .connecting)
                            }
                            completion?(true)
                        }
                    })
                }
            }
        }
    }
    
    func endCall(uuid: UUID) {
        
        func sendEndMessage(call: Call, category: MessageCategory) {
            let msg = Message.createWebRTCMessage(conversationId: call.conversationId,
                                                  category: category,
                                                  status: .SENDING,
                                                  quoteMessageId: call.uuidString)
            SendMessageService.shared.sendWebRTCMessage(message: msg, recipientId: call.opponentUser.userId)
            insertCallCompletedMessage(call: call,
                                       isUserInitiated: true,
                                       category: category)
        }
        
        queue.async {
            if let call = self.call, call.uuid == uuid {
                self.unansweredTimer?.invalidate()
                DispatchQueue.main.sync {
                    self.viewController?.style = .disconnecting
                }
                self.ringtonePlayer?.stop()
                self.rtcClient.close()
                let category: MessageCategory
                if call.connectedDate != nil {
                    category = .WEBRTC_AUDIO_END
                } else if call.isOutgoing {
                    category = .WEBRTC_AUDIO_CANCEL
                } else {
                    category = .WEBRTC_AUDIO_DECLINE
                }
                sendEndMessage(call: call, category: category)
                self.call = nil
                self.isMuted = false
                self.usesSpeaker = false
                DispatchQueue.main.sync(execute: self.dismissCallingInterface)
            } else if let (call, _) = self.pendingOffers.removeValue(forKey: uuid) {
                sendEndMessage(call: call, category: .WEBRTC_AUDIO_DECLINE)
                if self.pendingOffers.isEmpty {
                    self.ringtonePlayer?.stop()
                    if self.call == nil {
                        DispatchQueue.main.sync(execute: self.dismissCallingInterface)
                    }
                }
            } else {
                DispatchQueue.main.sync(execute: self.dismissCallingInterface)
                self.usesSpeaker = false
                self.isMuted = false
            }
            self.pendingCandidates[uuid] = nil
        }
    }
    
    func clean() {
        rtcClient.close()
        call = nil
        pendingOffers = [:]
        isMuted = false
        usesSpeaker = false
        ringtonePlayer?.stop()
        unansweredTimer?.invalidate()
        performSynchronouslyOnMainThread {
            vibrator.stop()
            dismissCallingInterface()
        }
    }
    
}

extension CallManager: CallMessageCoordinator {
    
    func shouldSendRtcBlazeMessage(with category: MessageCategory) -> Bool {
        let onlySendIfThereIsAnActiveCall = [.WEBRTC_AUDIO_OFFER, .WEBRTC_AUDIO_ANSWER, .WEBRTC_ICE_CANDIDATE].contains(category)
        return call != nil || !onlySendIfThereIsAnActiveCall
    }
    
    func handleIncomingBlazeMessageData(_ data: BlazeMessageData) {
        queue.async {
            switch data.category {
            case MessageCategory.WEBRTC_AUDIO_OFFER.rawValue:
                self.handleOffer(data: data)
            case MessageCategory.WEBRTC_ICE_CANDIDATE.rawValue:
                self.handleIceCandidate(data: data)
            default:
                self.handleCallStatusChange(data: data)
            }
        }
    }
    
}

// MARK: - Blaze message data handlers
extension CallManager {
    
    private func handleOffer(data: BlazeMessageData) {
        
        func declineOffer(data: BlazeMessageData, category: MessageCategory) {
            let offer = Message.createWebRTCMessage(data: data, category: category, status: .DELIVERED)
            MessageDAO.shared.insertMessage(message: offer, messageSource: "")
            let reply = Message.createWebRTCMessage(quote: data, category: category, status: .SENDING)
            SendMessageService.shared.sendWebRTCMessage(message: reply, recipientId: data.getSenderId())
            if let uuid = UUID(uuidString: data.messageId) {
                pendingOffers.removeValue(forKey: uuid)
            }
        }
        
        do {
            guard let uuid = UUID(uuidString: data.messageId) else {
                throw CallError.invalidUUID(uuid: data.messageId)
            }
            guard let sdpString = data.data.base64Decoded(), let sdp = RTCSessionDescription(jsonString: sdpString) else {
                throw CallError.invalidSdp(sdp: data.data)
            }
            guard let user = UserDAO.shared.getUser(userId: data.userId) else {
                throw CallError.missingUser(userId: data.userId)
            }
            AudioManager.shared.pause()
            let call = Call(uuid: uuid, opponentUser: user, isOutgoing: false)
            pendingOffers[uuid] = PendingOffer(call: call, sdp: sdp)
            
            var reportingError: Error?
            let semaphore = DispatchSemaphore(value: 0)
            callInterface.reportNewIncomingCall(uuid: uuid, handle: .userId(user.userId), localizedCallerName: user.fullName) { (error) in
                reportingError = error
                semaphore.signal()
            }
            semaphore.wait()
            
            if let error = reportingError {
                throw error
            }
        } catch CallError.busy {
            declineOffer(data: data, category: .WEBRTC_AUDIO_BUSY)
        } catch CallError.microphonePermissionDenied {
            declineOffer(data: data, category: .WEBRTC_AUDIO_DECLINE)
            alert(error: .microphonePermissionDenied)
        } catch {
            declineOffer(data: data, category: .WEBRTC_AUDIO_FAILED)
        }
    }
    
    private func handleIceCandidate(data: BlazeMessageData) {
        guard let candidatesString = data.data.base64Decoded() else {
            return
        }
        let newCandidates = [RTCIceCandidate](jsonString: candidatesString)
        if let call = call, data.quoteMessageId == call.uuidString, rtcClient.canAddRemoteCandidate {
            newCandidates.forEach(rtcClient.add(remoteCandidate:))
        } else if let uuid = UUID(uuidString: data.quoteMessageId) {
            var candidates = pendingCandidates[uuid] ?? []
            candidates.append(contentsOf: newCandidates)
            pendingCandidates[uuid] = candidates
        }
    }
    
    private func handleCallStatusChange(data: BlazeMessageData) {
        guard let uuid = UUID(uuidString: data.quoteMessageId) else {
            return
        }
        if let call = call, uuid == call.uuid, call.isOutgoing, data.category == MessageCategory.WEBRTC_AUDIO_ANSWER.rawValue, let sdpString = data.data.base64Decoded(), let sdp = RTCSessionDescription(jsonString: sdpString) {
            unansweredTimer?.invalidate()
            callInterface.reportOutgoingCallStartedConnecting(uuid: uuid)
            ringtonePlayer?.stop()
            DispatchQueue.main.sync {
                viewController?.style = .connecting
            }
            rtcClient.set(remoteSdp: sdp) { (error) in
                if let error = error {
                    self.queue.async {
                        self.failCurrentCall(sendFailedMessageToRemote: true,
                                             error: .setRemoteAnswer(error))
                        self.callInterface.reportCall(uuid: uuid, endedByReason: .failed)
                    }
                }
            }
        } else if let category = MessageCategory(rawValue: data.category), MessageCategory.endCallCategories.contains(category) {
            
            func insertMessageAndReport(call: Call) {
                insertCallCompletedMessage(call: call, isUserInitiated: false, category: category)
                callInterface.reportCall(uuid: call.uuid, endedByReason: .remoteEnded)
            }
            
            if let call = call, call.uuid == uuid {
                DispatchQueue.main.sync {
                    viewController?.style = .disconnecting
                }
                insertMessageAndReport(call: call)
                clean()
            } else if let call = pendingOffers[uuid]?.call {
                ringtonePlayer?.stop()
                insertMessageAndReport(call: call)
                pendingOffers.removeValue(forKey: uuid)
            }
        }
    }
    
    private func insertCallCompletedMessage(call: Call, isUserInitiated: Bool, category: MessageCategory?) {
        let timeIntervalSinceNow = call.connectedDate?.timeIntervalSinceNow ?? 0
        let duration = abs(timeIntervalSinceNow * millisecondsPerSecond)
        let category = category ?? .WEBRTC_AUDIO_FAILED
        let shouldMarkMessageRead = call.isOutgoing
            || category == .WEBRTC_AUDIO_END
            || (category == .WEBRTC_AUDIO_DECLINE && isUserInitiated)
        let status: MessageStatus = shouldMarkMessageRead ? .READ : .DELIVERED
        let msg = Message.createWebRTCMessage(messageId: call.uuidString,
                                              conversationId: call.conversationId,
                                              userId: call.raisedByUserId,
                                              category: category,
                                              mediaDuration: Int64(duration),
                                              status: status)
        MessageDAO.shared.insertMessage(message: msg, messageSource: "")
    }
    
}

extension CallManager: WebRTCClientDelegate {
    
    func webRTCClient(_ client: WebRTCClient, didGenerateLocalCandidate candidate: RTCIceCandidate) {
        guard let call = call, let content = [candidate].jsonString else {
            return
        }
        let msg = Message.createWebRTCMessage(conversationId: call.conversationId,
                                              category: .WEBRTC_ICE_CANDIDATE,
                                              content: content,
                                              status: .SENDING,
                                              quoteMessageId: call.uuidString)
        SendMessageService.shared.sendMessage(message: msg,
                                              ownerUser: call.opponentUser,
                                              isGroupMessage: false)
    }
    
    func webRTCClientDidConnected(_ client: WebRTCClient) {
        queue.async {
            guard let call = self.call else {
                return
            }
            let date = Date()
            call.connectedDate = date
            if call.isOutgoing {
                self.callInterface.reportOutgoingCall(uuid: call.uuid, connectedAtDate: date)
            } else {
                self.callInterface.reportIncomingCall(uuid: call.uuid, connectedAtDate: date)
            }
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            DispatchQueue.main.sync {
                self.viewController?.style = .connected
            }
        }
    }
    
    func webRTCClientDidFailed(_ client: WebRTCClient) {
        queue.async {
            self.failCurrentCall(sendFailedMessageToRemote: true, error: .clientFailure)
        }
    }
    
}

extension CallManager {
    
    @objc private func unansweredTimeout() {
        guard let call = call, !call.hasReceivedRemoteAnswer else {
            return
        }
        dismissCallingInterface()
        rtcClient.close()
        isMuted = false
        queue.async {
            self.ringtonePlayer?.stop()
            let msg = Message.createWebRTCMessage(conversationId: call.conversationId,
                                                  category: .WEBRTC_AUDIO_CANCEL,
                                                  status: .SENDING,
                                                  quoteMessageId: call.uuidString)
            SendMessageService.shared.sendWebRTCMessage(message: msg, recipientId: call.opponentUser.userId)
            self.insertCallCompletedMessage(call: call, isUserInitiated: false, category: .WEBRTC_AUDIO_CANCEL)
            self.call = nil
            self.callInterface.reportCall(uuid: call.uuid, endedByReason: .unanswered)
        }
    }
    
    @objc private func audioSessionRouteChange(_ notification: Notification) {
        guard call != nil else {
            return
        }
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(port)
    }
    
    private func failCurrentCall(sendFailedMessageToRemote: Bool, error: CallError) {
        guard let call = call else {
            return
        }
        if sendFailedMessageToRemote {
            let msg = Message.createWebRTCMessage(conversationId: call.conversationId,
                                                  category: .WEBRTC_AUDIO_FAILED,
                                                  status: .SENDING,
                                                  quoteMessageId: call.uuidString)
            SendMessageService.shared.sendMessage(message: msg,
                                                  ownerUser: call.opponentUser,
                                                  isGroupMessage: false)
        }
        let failedMessage = Message.createWebRTCMessage(messageId: call.uuidString,
                                                        conversationId: call.conversationId,
                                                        category: .WEBRTC_AUDIO_FAILED,
                                                        status: .DELIVERED)
        MessageDAO.shared.insertMessage(message: failedMessage, messageSource: "")
        clean()
        reporter.report(error: error)
    }
    
    private func playRingtone(usesSpeaker: Bool) {
        if usesSpeaker {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
        } else {
            try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [])
        }
        ringtonePlayer?.play()
    }
    
}
