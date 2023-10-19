import UIKit
import AVKit
import AVFoundation
import RealmSwift
import PutioAPI

class VideoPlayerViewController: AVPlayerViewController {
    let realm = try! Realm()
    var item: MediaPlayerItem!
    var timer: Timer?
    var user: User = {
        let realm = try! Realm()
        return realm.objects(User.self).first!
    }()

    var isPlayerSetup: Bool = false
    var isPlayingInPictureOnPictureMode: Bool = false

    override var prefersStatusBarHidden: Bool {
        return true
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setupPlayer()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        timer?.invalidate()
        if !isPlayingInPictureOnPictureMode {
            onPlaybackStopped()
            player?.pause()
        }
    }

    func getInitialVideoTime(completion: @escaping (_ time: Int) -> Void) {
        if item.consumptionType == .offline {
            guard item.startFrom > 0 else { return completion(0) }
            return showStartFromDialog(item.startFrom) { (selectedStartFrom) in completion(selectedStartFrom) }
        }

        api.getStartFrom(fileID: item.id) { result in
            switch result {
            case .success(let startFrom):
                guard startFrom > 0 else {
                    return completion(0)
                }

                self.showStartFromDialog(startFrom) { completion($0) }

            case .failure:
                completion(0)
            }
        }
    }

    func showStartFromDialog(_ startFrom: Int, completion: @escaping (_ time: Int) -> Void) {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .positional
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.zeroFormattingBehavior = [.pad]

        guard let timestamp = formatter.string(from: Double(startFrom)) else { return completion(0) }

        let alert = UIAlertController(title: "Where would you like to start?", message: "Last saved timestamp for this video is \(timestamp)", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Continue watching", style: .default, handler: { (_) in completion(startFrom) }))
        alert.addAction(UIAlertAction(title: "Start from the beginning", style: .default, handler: { (_) in completion(0) }))

        present(alert, animated: true, completion: nil)
    }

    func setupPlayer() {
        if isPlayerSetup { return }

        getInitialVideoTime { (startFrom) in
            self.isPlayerSetup = true
            self.player?.seek(to: CMTimeMakeWithSeconds(Float64(startFrom), 600))
            self.player?.play()
            self.onPlaybackStarted()
            self.timer = Timer.scheduledTimer(
                timeInterval: 10,
                target: self,
                selector: #selector(self.saveVideoTime),
                userInfo: nil,
                repeats: true
            )
        }
    }

    func getCurrentTimeAndDuration() -> (Int, Int)? {
        guard player?.currentItem?.status == .readyToPlay,
            let currentTime = player?.currentTime().seconds,
            let duration = player?.currentItem?.duration.seconds,
            !duration.isNaN && !duration.isInfinite && !currentTime.isNaN && !currentTime.isInfinite else { return nil }

        return (Int(currentTime), Int(duration))
    }

    @objc func saveVideoTime() {
        guard user.settings != nil, user.settings?.rememberVideoTime == true else { return }
        guard let (currentTime, duration) = getCurrentTimeAndDuration() else { return }

        if currentTime == duration { return }

        if item.consumptionType == .online {
            return api.setStartFrom(fileID: item.id, time: currentTime, completion: { _ in })
        }

        guard let download = realm.object(ofType: Download.self, forPrimaryKey: item.id) else { return }

        try! realm.write {
            download.startFrom = (currentTime >= duration - 10) ? 0 : currentTime
        }
    }

    func onPlaybackStarted() {
        let iftttEvent = PutioIFTTTPlaybackEvent(
            eventType: "playback_started",
            ingredients: PutioIFTTTPlaybackEventIngredients(
                fileId: item.id,
                fileName: item.name,
                fileType: "VIDEO"
            )
        )

        api.sendIFTTTEvent(event: iftttEvent, completion: { _ in })
    }

    func onPlaybackStopped() {
        let iftttEvent = PutioIFTTTPlaybackEvent(
            eventType: "playback_stopped",
            ingredients: PutioIFTTTPlaybackEventIngredients(
                fileId: item.id,
                fileName: item.name,
                fileType: "VIDEO"
            )
        )

        api.sendIFTTTEvent(event: iftttEvent, completion: { _ in })
    }
}
