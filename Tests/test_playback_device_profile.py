import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).parents[1]


class PlaybackDeviceProfileTests(unittest.TestCase):
    def setUp(self):
        self.profile = (ROOT / "HappiE" / "PlaybackDeviceProfile.swift").read_text()

    def test_av1_is_only_claimed_when_device_gate_is_true(self):
        av1_append = self.profile.index('videoCodecs.append("av1")')
        av1_gate = self.profile.rfind("if allowsAV1 {", 0, av1_append)
        self.assertNotEqual(-1, av1_gate)
        self.assertNotIn('"av1"', self.profile[self.profile.index("var videoCodecs"):av1_gate])

    def test_avplayer_direct_play_baseline_includes_mp4_h264(self):
        self.assertIn('containers: ["mp4"', self.profile)
        self.assertIn('var videoCodecs = ["h264"]', self.profile)

    def test_dolby_vision_is_native_hdr_hevc_only(self):
        self.assertRegex(
            self.profile,
            re.compile(
                r"dolbyVisionProfiles: allowsDolbyVision \&\& allowsHEVC \? \[5, 8\] : \[\]"
            ),
        )

    def test_bitrate_never_falls_below_floor(self):
        self.assertIn("minimumBitrate = 420_000", self.profile)
        self.assertIn("maxBitrate: max(minimumBitrate, maxBitrate)", self.profile)


if __name__ == "__main__":
    unittest.main()
