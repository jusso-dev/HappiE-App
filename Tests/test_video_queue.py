import json
import pathlib
import unittest


ROOT = pathlib.Path(__file__).parents[1]


def next_video(current, videos, series_id):
    """Executable fixture specification for VideoQueue's ordering contract."""
    if "episodeNumber" not in current:
        return next((video for video in videos if video["id"] != current["id"]), None)

    current_position = (current.get("seasonNumber", 0), current["episodeNumber"])
    candidates = [
        video
        for video in videos
        if video["id"] != current["id"]
        and video.get("seriesId") == series_id
        and "episodeNumber" in video
        and (video.get("seasonNumber", 0), video["episodeNumber"]) > current_position
    ]
    return min(
        candidates,
        key=lambda video: (video.get("seasonNumber", 0), video["episodeNumber"]),
        default=None,
    )


class VideoQueueTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        fixture = json.loads((ROOT / "Tests/Fixtures/series_manifest.json").read_text())
        cls.series_id = fixture["seriesId"]
        cls.videos = fixture["videos"]
        for video in cls.videos:
            if "episodeNumber" in video:
                video["seriesId"] = cls.series_id

    def test_next_episode_is_series_aware_and_ordered(self):
        result = next_video(self.videos[0], self.videos, self.series_id)
        self.assertEqual("Episode 2", result["title"])

    def test_last_episode_has_no_bogus_next(self):
        result = next_video(self.videos[2], self.videos, self.series_id)
        self.assertIsNone(result)

    def test_flat_library_keeps_first_other_video_behavior(self):
        movie = self.videos[1]
        result = next_video(movie, self.videos, self.series_id)
        self.assertEqual("Episode 1", result["title"])

    def test_player_uses_queue_helper_after_reporting_completion(self):
        source = (ROOT / "HappiE/PlayerView.swift").read_text()
        self.assertIn("VideoQueue.next(after: currentItem.video, in: playerVideos)", source)
        ended = source.split("private func handleVideoEnded()", 1)[1].split(
            "private func startUpNextCountdown", 1
        )[0]
        self.assertLess(ended.index("reportProgress("), ended.index("startUpNextCountdown"))


if __name__ == "__main__":
    unittest.main()
