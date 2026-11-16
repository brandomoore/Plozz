"""Regression tests for the UI loading-state guard.

The guard exists because both anti-patterns shipped and both were reported by a
viewer: a skeleton armed by a delay (Home 250ms -> 2s -> 6s, detail rail 250ms)
and a skeleton suppressed without reserving its geometry (detail episode rail).
"""
import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("ui_state_guard", ROOT / "tools" / "ui-state-guard.py")
guard = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(guard)


class UILoadingStateGuardTests(unittest.TestCase):
    def write(self, name: str, body: str) -> pathlib.Path:
        directory = pathlib.Path(self.enterContext(__import__("tempfile").TemporaryDirectory()))
        path = directory / name
        path.write_text(body)
        return path

    def test_flags_skeleton_armed_after_sleep(self) -> None:
        path = self.write("Home.swift", """
        struct Home: View {
            @State private var skeletonArmed = false
            var body: some View {
                Color.clear.task {
                    try? await Task.sleep(for: .milliseconds(250))
                    skeletonArmed = true
                }
            }
        }
        """)
        self.assertTrue(guard.check_time_gated_loading(path))

    def test_allows_background_sleep_without_loading_flag(self) -> None:
        path = self.write("Refresh.swift", """
        struct Refresh {
            func run() async {
                try? await Task.sleep(for: .seconds(20))
                await refresh()
            }
        }
        """)
        self.assertEqual(guard.check_time_gated_loading(path), [])

    def test_flags_conditionally_shown_skeleton(self) -> None:
        path = self.write("Rail.swift", """
        struct Rail: View {
            var body: some View {
                if isLoading {
                    EpisodeSkeletonRail()
                } else {
                    RailContent()
                }
            }
        }
        """)
        self.assertTrue(guard.check_reserved_geometry(path))

    def test_title_navigation_stays_fixed_without_a_zoom_morph(self) -> None:
        # A zoom destination scales the whole page with the interactive back-swipe,
        # which reads as the hero resizing/bouncing while the finger is still down.
        # Card routes were changed once but the path destinations kept the morph,
        # so pin the whole app shell.
        offenders = sorted(
            path.relative_to(ROOT).as_posix()
            for path in (ROOT / "Sources" / "AppShelliOS").rglob("*.swift")
            if ".mediaArtworkZoomDestination(" in path.read_text()
        )
        self.assertEqual(offenders, [], "title routes must use the standard push")
        zoom = (ROOT / "Sources" / "CoreUI" / "MediaArtworkZoom.swift").read_text()
        self.assertIn("usesZoom: Bool = false,", zoom)
        # The detail hero additionally freezes its pull-stretch for the duration of
        # the native edge back-swipe: the system pan can deliver a small vertical
        # component to the page's scroll view, which used to bounce the picture.
        detail = (ROOT / "Sources" / "AppShelliOS" / "PlozziOSItemDetailView.swift").read_text()
        self.assertIn("PlozziOSInteractivePopObserver(isActive: $isInteractivePopActive)", detail)
        self.assertIn(".scrollDisabled(isInteractivePopActive)", detail)
        self.assertIn("guard !isInteractivePopActive else { return }", detail)
        self.assertIn("guard pullDistance == 0 || isHeroScrollActive else { return }", detail)
        # A detail hero must size from its own layout. The navigation transition
        # moves its global x every frame, and using that as "covered width"
        # re-crops the artwork (the hero visibly resizing on push and back).
        hero = (ROOT / "Sources/AppShelliOS/PlozziOSHeroViews.swift").read_text()
        self.assertIn("ignoresGlobalCover: surfaceRole == .detail", hero)
        self.assertIn("let width = ignoresGlobalCover", hero)
        self.assertIn("? proxy.size.width", hero)
        # A slow horizontal wiggle must not swap the incoming slide between the
        # previous/next item while the finger is still down.
        home = (ROOT / "Sources/AppShelliOS/PlozziOSHomeView.swift").read_text()
        self.assertIn("dragTargetID", home)
        # The production detail page must not prefetch the opening season's
        # episodes during the push; the rail loads when it is shown (upstream).
        environment = (ROOT / "Sources/FeatureHomeCore/DetailOpenEnvironment.swift").read_text()
        self.assertIn("prefetchesOpeningSeason: false", environment)
        view_model = (ROOT / "Sources/FeatureHomeCore/ItemDetailViewModel.swift").read_text()
        self.assertIn("prefetchesOpeningSeason: Bool = false", view_model)
        # A window-wide cover installed for the push blocked every touch on the
        # destination until the transition completed. It was a fork-only gate;
        # upstream lets the pushed page accept input as soon as it is interactive.
        proxy = (ROOT / "Sources/AppShelliOS/PlozziOSNavigationPopProxy.swift").read_text()
        self.assertNotIn("pushShield", proxy)

    def test_allows_reserved_placeholder(self) -> None:
        path = self.write("Rail.swift", """
        struct Rail: View {
            var body: some View {
                PlozzReservedPlaceholder(isPending: isLoading, revealsPlaceholder: false) {
                    EpisodeSkeletonRail()
                } content: {
                    RailContent()
                }
            }
        }
        """)
        self.assertEqual(guard.check_reserved_geometry(path), [])


if __name__ == "__main__":
    unittest.main()
