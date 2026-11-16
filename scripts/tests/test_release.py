from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release
import macos_signing


class ReleaseGuards(unittest.TestCase):
    def test_dirty_tree_is_refused_even_in_test_mode(self):
        with patch.object(release, "run", return_value=b" M README.md"):
            with self.assertRaisesRegex(ValueError, "clean"):
                release.preflight(True)

    def test_review_branch_cannot_be_a_real_release(self):
        with patch.object(release, "run", side_effect=[b"", b"abc\n", b"release/developer-id\n"]):
            with self.assertRaisesRegex(ValueError, "main"):
                release.preflight(False)
        with patch.object(release, "run", side_effect=[b"", b"abc\n", b"release/developer-id\n"]):
            self.assertEqual(release.preflight(True), "abc")

    def test_main_must_match_public_reviewed_commit(self):
        with patch.object(release, "run", side_effect=[b"", b"abc\n", b"main\n", b"abc\n", b"def refs/heads/main\n"]):
            with self.assertRaisesRegex(ValueError, "origin/main"):
                release.preflight(False)

    def test_credential_failure_never_echoes_tool_output(self):
        result = subprocess.CompletedProcess([], 1, stdout=b"sensitive", stderr=b"sensitive")
        with patch.object(subprocess, "run", return_value=result):
            with self.assertRaises(ValueError) as failure:
                macos_signing.run("sign_update", sensitive=True)
        self.assertNotIn("sensitive", str(failure.exception))

    def test_appcast_binds_archive_size_version_and_signature(self):
        with tempfile.TemporaryDirectory() as root:
            archive = Path(root) / "CatGuard-0.2.0.zip"
            archive.write_bytes(b"test archive")
            feed = Path(root) / "appcast.xml"
            release.write_appcast(feed, archive, "public-signature", "0.2.0", "2")
            item = ET.parse(feed).find("./channel/item")
            self.assertEqual(item.find(f"{{{release.SPARKLE_NS}}}version").text, "2")
            enclosure = item.find("enclosure")
            self.assertEqual(enclosure.attrib["length"], str(archive.stat().st_size))
            self.assertEqual(enclosure.attrib[f"{{{release.SPARKLE_NS}}}edSignature"], "public-signature")
            self.assertEqual(enclosure.attrib["url"], "https://github.com/oana-ffg/catguard/releases/download/v0.2.0/CatGuard-0.2.0.zip")

    def test_partially_attached_credential_image_is_detached_before_trashing(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            with patch.object(macos_signing, "attached_image_device", side_effect=["/dev/disk999", None]), \
                 patch.object(macos_signing, "run") as run, \
                 patch.object(macos_signing, "trash") as trash, \
                 patch.object(macos_signing.os.path, "ismount", return_value=False):
                macos_signing.remove_notary_container(root, root / "mount", root / "mount/key.p8")
                run.assert_called_once_with("hdiutil", "detach", "/dev/disk999", timeout=30)
                trash.assert_called_once_with(root)

    def test_failed_detach_retains_credential_container_and_surfaces_error(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            with patch.object(macos_signing, "attached_image_device", return_value="/dev/disk999"), \
                 patch.object(macos_signing, "run", side_effect=ValueError("detach failed")) as run, \
                 patch.object(macos_signing, "trash") as trash:
                with self.assertRaisesRegex(ValueError, "detach failed"):
                    macos_signing.remove_notary_container(root, root / "mount", root / "mount/key.p8")
                self.assertEqual(run.call_count, 2)
                trash.assert_not_called()

    def test_credential_cleanup_failure_retains_original_error(self):
        def failed_cleanup():
            raise OSError("detach failed")
        try:
            raise ValueError("submission failed")
        except ValueError:
            with self.assertRaisesRegex(ValueError, "submission failed.*detach failed"):
                macos_signing.cleanup_preserving_error(failed_cleanup)


if __name__ == "__main__":
    unittest.main()
