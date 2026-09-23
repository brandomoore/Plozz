from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class DetectedSetupCopyTests(unittest.TestCase):
    def test_import_invitation_preserves_logos_and_existing_actions(self):
        source = (ROOT / "Sources/AppShelliOS/PlozziOSDetectedSetupView.swift").read_text()
        self.assertIn('Image("PlozzLogo")', source)
        self.assertIn("ProviderBrandMark(provider: group.provider", source)
        self.assertIn('case "tv": return "appletv.fill"', source)
        self.assertIn("ServerImportHeading(content: importContent, deviceName: originName, deviceIcon: originIcon)", source)
        self.assertIn("Button(action: onSetUpFromDevice)", source)
        self.assertIn("Button(action: onSetUpLater)", source)
        self.assertIn("Text(importContent.primaryAction)", source)
        self.assertIn('Text("Import later in Settings")', source)
        self.assertIn('Text("Account: \\(joined)")', source)
        self.assertIn('Text("Accounts: \\(joined)")', source)
        self.assertNotIn('Text("Set Up")', source)
        self.assertNotIn('Text("From ', source)
        self.assertNotIn("Use the same server connection", source)
        self.assertNotIn("We found your server", source)

    def test_origin_names_are_deduplicated_not_misattributed_to_only_first_device(self):
        source = (ROOT / "Sources/AppShelliOS/PlozziOSDetectedSetupView.swift").read_text()
        self.assertIn("seen.insert($0).inserted", source)
        self.assertIn("names.formatted(.list(type: .and).locale(locale))", source)
        self.assertIn('case "pad": return "ipad"', source)
        self.assertIn('case "phone": return "iphone"', source)
        self.assertIn('case "mac": return "desktopcomputer"', source)
        heading = (ROOT / "Sources/CoreUI/ServerImportHeading.swift").read_text()
        self.assertIn('Text(verbatim: "\\u{00a0}" + deviceName)', heading,
                      "The device icon must travel with the device name when the heading wraps")
        self.assertIn(".fontWeight(.bold)", heading)
        self.assertNotIn("brandBlue", heading)


if __name__ == "__main__":
    unittest.main()
