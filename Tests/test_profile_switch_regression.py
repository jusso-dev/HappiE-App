import pathlib
import unittest


class ProfileSwitchRegressionTests(unittest.TestCase):
    def test_profile_picker_is_not_dismissed_when_scene_is_temporarily_inactive(self):
        """Only a real background transition should restore the child-safe screen."""
        source = (
            pathlib.Path(__file__).parents[1] / "HappiE" / "ContentView.swift"
        ).read_text()

        scene_phase_handler = source.split(".onChange(of: scenePhase)", 1)[1].split(
            ".fullScreenCover", 1
        )[0]

        self.assertIn("newPhase == .background", scene_phase_handler)
        self.assertNotIn("newPhase != .active", scene_phase_handler)


if __name__ == "__main__":
    unittest.main()
