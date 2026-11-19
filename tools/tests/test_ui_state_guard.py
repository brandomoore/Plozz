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

    def test_title_navigation_uses_the_native_zoom_transition(self) -> None:
        # Upstream restored the artwork zoom transition for title routes. The
        # resize/bounce it used to cause is prevented by the invariants below:
        # the detail hero sizes from its own layout and freezes its pull-stretch
        # while the interactive pop is active, so every title route opts in.
        for name in [
            "PlozziOSHomeView.swift",
            "PlozziOSItemNavigation.swift",
            "PlozziOSLibraryView.swift",
            "PlozziOSLibraryRoute.swift",
        ]:
            self.assertIn(
                ".mediaArtworkZoomDestination(",
                (ROOT / "Sources" / "AppShelliOS" / name).read_text(),
                f"{name} must opt into the shared artwork zoom transition",
            )
        zoom = (ROOT / "Sources" / "CoreUI" / "MediaArtworkZoom.swift").read_text()
        self.assertIn("navigationTransition(.zoom(sourceID: source.id, in: source.namespace))", zoom)
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
        # The Home hero must not swap a visible title/wordmark for a late logo
        # after enrichment; that reads as clear-text flickering/competing slides.
        self.assertIn("frozenLogoChoice", hero)
        self.assertIn("logoReferencesOverride: frozenLogoChoice ? frozenLogoReferences : nil", hero)
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
