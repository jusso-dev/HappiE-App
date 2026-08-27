import pathlib
import unittest


ROOT = pathlib.Path(__file__).parents[1]


class LiveWatchProgressRegressionTests(unittest.TestCase):
    def test_progress_updates_local_history_before_network_reporting(self):
        source = (ROOT / "HappiE" / "AppModel.swift").read_text()
        method = source.split("func reportPlaybackProgress", 1)[1].split(
            "@discardableResult", 1
        )[0]

        local_patch = method.index("history.updateProgress")
        network_task = method.index("Task {")
        self.assertLess(local_patch, network_task)
        self.assertIn("completed: progress.completed", method)

    def test_completion_is_sticky_for_late_close_callbacks(self):
        source = (ROOT / "HappiE" / "WatchHistoryStore.swift").read_text()
        method = source.split("func updateProgress", 1)[1].split("func clear", 1)[0]

        self.assertIn("entry.completed = completed || entry.completed", method)
        self.assertIn("return entry", method)


if __name__ == "__main__":
    unittest.main()
