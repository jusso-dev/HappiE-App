import pathlib
import unittest


ROOT = pathlib.Path(__file__).parents[1]


class MediaPlayerManagerRegressionTests(unittest.TestCase):
    def test_screen_consumes_backend_neutral_events(self):
        source = (ROOT / "HappiE" / "PlayerView.swift").read_text()
        self.assertIn("@StateObject private var controller: MediaPlayerManager", source)
        self.assertIn(".onChange(of: controller.endedEvent)", source)
        self.assertIn(".onChange(of: controller.stalledEvent)", source)
        self.assertNotIn("publisher(for: AVPlayerItem.didPlayToEndTimeNotification)", source)

    def test_vlc_is_optional_and_apple_is_the_unlinked_default(self):
        source = (ROOT / "HappiE" / "MediaPlayerManager.swift").read_text()
        self.assertIn("#if canImport(MobileVLCKit)", source)
        self.assertIn("self.engine = .apple", source)
        self.assertIn("case .ended:", source)
        self.assertIn("endedEvent = UUID()", source)

    def test_playback_request_has_device_profile_hint(self):
        source = (ROOT / "HappiE" / "HappiEAPI.swift").read_text()
        self.assertIn('URLQueryItem(name: "device_profile", value: encodedProfile)', source)


if __name__ == "__main__":
    unittest.main()
