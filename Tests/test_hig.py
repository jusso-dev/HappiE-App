import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).parents[1]
VIEWS = ["ContentView", "HomeView", "HistoryView", "ParentGate", "ParentControlsView", "PlayerView", "Theme"]


class HumanInterfaceGuidelinesTests(unittest.TestCase):
    def test_text_scales_with_dynamic_type(self):
        """Rounded text uses scaledFont; only the logo and avatar letters stay fixed."""
        fixed = []
        for name in VIEWS:
            source = (ROOT / "HappiE" / f"{name}.swift").read_text()
            for match in re.finditer(r"\.font\(\.system\(size: ([^,]+),[^)]*design: \.rounded\)\)", source):
                if match.group(1) not in {"size * 0.44", "markSize * 0.68"}:
                    fixed.append(f"{name}: {match.group(0)}")
        self.assertEqual(fixed, [])

    def test_scaled_font_tracks_a_text_style(self):
        theme = (ROOT / "HappiE" / "Theme.swift").read_text()
        self.assertIn("@ScaledMetric private var size: CGFloat", theme)
        self.assertIn("ScaledMetric(wrappedValue: size, relativeTo: textStyle)", theme)

    def test_small_red_text_uses_the_accessible_red(self):
        """`accent` is ~4:1 on white; small text needs 4.5:1, so text uses accentText."""
        for name in VIEWS:
            source = (ROOT / "HappiE" / f"{name}.swift").read_text()
            for match in re.finditer(r"(Text|Label)\([^\n]*\n(?:[^\n]*\n){0,2}[^\n]*foregroundStyle\(HTheme\.accent\)", source):
                self.fail(f"{name}: text styled with HTheme.accent: {match.group(0)!r}")

    def test_splash_respects_reduce_motion(self):
        content = (ROOT / "HappiE" / "ContentView.swift").read_text()
        splash = content.split("private struct WelcomeSplashView", 1)[1].split("private struct LoadingView", 1)[0]
        self.assertIn("accessibilityReduceMotion", splash)


if __name__ == "__main__":
    unittest.main()
