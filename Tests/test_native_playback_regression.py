import pathlib
import unittest


class NativePlaybackRegressionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.player_source = (
            pathlib.Path(__file__).parents[1] / "HappiE" / "PlayerView.swift"
        ).read_text()
        cls.manager_source = (
            pathlib.Path(__file__).parents[1] / "HappiE" / "MediaPlayerManager.swift"
        ).read_text()

    def test_play_applies_the_parent_playback_rate(self):
        play_method = self.manager_source.split("func play()", 1)[1].split(
            "private static var storedPlaybackRate", 1
        )[0]

        self.assertIn("playImmediately(atRate: Self.storedPlaybackRate)", play_method)
        self.assertIn('"HappiEPlaybackRate"', self.manager_source)

    def test_progress_observer_reports_media_position(self):
        observer = self.manager_source.split("private func addAVTimeObserver()", 1)[1].split(
            "private func observeAVEvents", 1
        )[0]

        self.assertIn("currentTime = time.seconds.isFinite ? time.seconds : 0", observer)
        self.assertNotIn("storedPlaybackRate", observer)

    def test_native_player_enables_pip_and_external_playback(self):
        native_player = self.player_source.split(
            "private struct NativeVideoPlayer", 1
        )[1].split("private final class PlayerLayerView", 1)[0]

        self.assertIn("configurePictureInPicture", native_player)
        self.assertIn("allowsExternalPlayback = true", native_player)
        self.assertIn("usesExternalPlaybackWhileExternalScreenIsActive = true", native_player)


if __name__ == "__main__":
    unittest.main()
