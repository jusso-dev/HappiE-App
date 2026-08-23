import pathlib
import unittest


class MediaTrackIndexMapTests(unittest.TestCase):
    def test_maps_sparse_stream_indexes_and_off(self):
        source = (pathlib.Path(__file__).parents[1] / "HappiE" / "MediaTrackIndexMap.swift").read_text()
        self.assertIn("streamIndexes.firstIndex(of: streamIndex)", source)
        self.assertIn("guard streamIndex >= 0 else { return nil }", source)
        self.assertIn("guard let offset, streamIndexes.indices.contains(offset) else { return -1 }", source)
        self.assertIn("return streamIndexes[offset]", source)


if __name__ == "__main__":
    unittest.main()
