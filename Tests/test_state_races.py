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

    def test_single_window_so_stores_are_not_duplicated(self):
        info = plistlib.loads((ROOT / "HappiE" / "Info.plist").read_bytes())

        self.assertFalse(info["UIApplicationSceneManifest"]["UIApplicationSupportsMultipleScenes"])


if __name__ == "__main__":
    unittest.main()
