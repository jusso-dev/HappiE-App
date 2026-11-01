import pathlib
import plistlib
import unittest


ROOT = pathlib.Path(__file__).parents[1]


def source(name):
    return (ROOT / "HappiE" / name).read_text()


class StateRaceRegressionTests(unittest.TestCase):
    def test_parent_controls_open_after_the_gate_dismisses(self):
        content = source("ContentView.swift")
        gate_sheet = content.split(".sheet(isPresented: $isShowingParentGate", 1)[1].split(
            ".sheet(isPresented: $isShowingParentControls", 1
        )[0]

        self.assertIn("onDismiss:", gate_sheet)
        self.assertIn("isShowingParentControls = true", gate_sheet.split("ParentGateView", 1)[0])

    def test_track_picker_waits_for_gate_dismissal_not_a_timer(self):
        player = source("PlayerView.swift")
        gate_sheet = player.split(".sheet(isPresented: $isShowingTrackGate", 1)[1].split(
            ".sheet(isPresented: $isShowingTrackPicker", 1
        )[0]

        self.assertIn("onDismiss:", gate_sheet)
        self.assertNotIn("Task.sleep", gate_sheet)

    def test_stale_download_callbacks_are_ignored(self):
        offline = source("OfflineStore.swift")
        download = offline.split("func download(_ video: ManifestVideo)", 1)[1].split(
            "func cancelDownload", 1
        )[0]
        cancel = offline.split("func cancelDownload", 1)[1].split("func removeDownload", 1)[0]

        self.assertEqual(download.count("downloadTokens[videoId] == token"), 2)
        self.assertIn("downloadTokens[videoId] = nil", cancel)

    def test_download_completion_only_writes_the_live_file_after_the_token_check(self):
        offline = source("OfflineStore.swift")
        download = offline.split("func download(_ video: ManifestVideo)", 1)[1].split(
            "private static func promote", 1
        )[0]
        background, main_actor = download.split("Task { @MainActor", 1)

        # Off the main actor the finished file only ever goes to staging.
        self.assertIn("moveItem(at: tempURL, to: staging)", background)
        self.assertNotIn("destination", background.split("let succeeded", 1)[1])
        # The live destination is written only after the token matches.
        self.assertLess(
            main_actor.index("downloadTokens[videoId] == token"),
            main_actor.index("promote(staging, to: destination)"),
        )
        self.assertIn("removeItem(at: staging)", main_actor.split("downloadTokens[videoId] = nil", 1)[0])

    def test_single_window_so_stores_are_not_duplicated(self):
        info = plistlib.loads((ROOT / "HappiE" / "Info.plist").read_bytes())

        self.assertFalse(info["UIApplicationSceneManifest"]["UIApplicationSupportsMultipleScenes"])

    def test_background_keeps_a_player_that_is_in_picture_in_picture(self):
        model = source("AppModel.swift")
        recover = model.split("func recoverForChildUse()", 1)[1].split("}", 1)[0]
        close = model.split("func closePlayer()", 1)[1].split("}", 1)[0]

        self.assertIn("guard !playerContinuesInBackground", recover)
        self.assertIn("playerContinuesInBackground = false", close)
        self.assertIn("onBackgroundPlaybackChange", source("ContentView.swift"))

    def test_background_continuation_follows_the_real_pip_lifecycle(self):
        player = source("PlayerView.swift")
        manager = source("MediaPlayerManager.swift")
        model = source("AppModel.swift")
        continues = player.split("private var continuesInBackground: Bool {", 1)[1].split("}", 1)[0]
        dismissed = model.split("func pictureInPictureDismissed()", 1)[1].split("\n    }", 1)[0]

        # Automatic PiP needs it to be possible for this item, not just the device.
        self.assertIn("isPictureInPicturePossible", continues)
        self.assertNotIn("isPictureInPictureSupported", continues)
        for delegate in ("WillStartPictureInPicture", "failedToStartPictureInPictureWithError",
                         "restoreUserInterfaceForPictureInPictureStop", "DidStopPictureInPicture"):
            self.assertIn(delegate, manager)
        self.assertIn("observe(\\.timeControlStatus", manager)
        # Closing PiP while backgrounded finishes the deferred recovery.
        self.assertIn("if isInBackground", dismissed)
        self.assertIn("playbackItem = nil", dismissed)


if __name__ == "__main__":
    unittest.main()
