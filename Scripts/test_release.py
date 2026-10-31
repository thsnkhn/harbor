#!/usr/bin/env python3
"""Check the update-feed contract used by existing Sparkle installations."""

import tempfile
import unittest
from pathlib import Path
import xml.etree.ElementTree as ET

import release


class MigrationFeedTests(unittest.TestCase):
    def setUp(self):
        self.previous = b'''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
          <item><sparkle:version>45</sparkle:version>
          <enclosure url="https://example.test/Harbor-1.8.6.dmg" length="123" sparkle:edSignature="old-signature"/>
          </item></channel></rss>'''
        self.packages = [
            dict(architecture="x86_64", file="Harbor-1.8.8-Intel.dmg", build="46.1", length=100,
                 minimum_system="15.6", signature="intel-signature", url="https://example.test/Harbor-1.8.8-Intel.dmg"),
            dict(architecture="arm64", file="Harbor-1.8.8-Apple-Silicon.dmg", build="46.2", length=200,
                 minimum_system="15.6", signature="arm-signature", url="https://example.test/Harbor-1.8.8-Apple-Silicon.dmg"),
        ]

    def testLegacyAndNativeFeedsKeepCompatibleUpdatesAndExactSignatures(self):
        namespace = {"s": release.SPARKLE}
        with tempfile.TemporaryDirectory() as temporary:
            release.generate_feeds(self.packages, "1.8.8", self.previous, temporary)
            legacy = ET.parse(Path(temporary) / "appcast.xml").findall("channel/item")
            self.assertEqual([item.findtext("s:version", namespaces=namespace) for item in legacy], ["46.2", "46.1", "45"])
            self.assertEqual(legacy[0].findtext("s:hardwareRequirements", namespaces=namespace), "arm64")
            self.assertIsNone(legacy[1].find("s:hardwareRequirements", namespace))
            self.assertEqual(legacy[0].find("enclosure").get(f"{{{release.SPARKLE}}}edSignature"), "arm-signature")
            self.assertEqual(legacy[1].find("enclosure").get(f"{{{release.SPARKLE}}}edSignature"), "intel-signature")
            for architecture, expected_file in (("arm64", "Harbor-1.8.8-Apple-Silicon.dmg"), ("x86_64", "Harbor-1.8.8-Intel.dmg")):
                items = ET.parse(Path(temporary) / f"appcast-{architecture}.xml").findall("channel/item")
                self.assertEqual(items[0].find("enclosure").get("url"), "https://example.test/" + expected_file)
                self.assertEqual(items[1].findtext("s:version", namespaces=namespace), "45")
            # A later release must not bring Intel packages into the Apple Silicon feed.
            previous = (Path(temporary) / "appcast.xml").read_bytes()
            for package in self.packages:
                package["build"] = package["build"].replace("46.", "47.")
                package["file"] = package["file"].replace("1.8.8", "1.8.9")
                package["url"] = package["url"].replace("1.8.8", "1.8.9")
            release.generate_feeds(self.packages, "1.8.9", previous, temporary)
            for architecture, forbidden in (("arm64", "-Intel.dmg"), ("x86_64", "-Apple-Silicon.dmg")):
                items = ET.parse(Path(temporary) / f"appcast-{architecture}.xml").findall("channel/item")
                self.assertFalse(any(item.find("enclosure").get("url").endswith(forbidden) for item in items))

    def testWrongProcessorMetadataAndNonIncreasingBuildsAreRejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            self.packages[0]["file"] = "Harbor-1.8.8-Apple-Silicon.dmg"
            with self.assertRaisesRegex(RuntimeError, "does not match"):
                release.generate_feeds(self.packages, "1.8.8", self.previous, temporary)
            self.packages[0]["file"] = "Harbor-1.8.8-Intel.dmg"
            previous = self.previous.replace(b">45<", b">47<")
            with self.assertRaisesRegex(RuntimeError, "must exceed"):
                release.generate_feeds(self.packages, "1.8.8", previous, temporary)


if __name__ == "__main__":
    unittest.main()
