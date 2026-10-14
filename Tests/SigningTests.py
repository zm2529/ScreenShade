import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("screenshade_build", Path(__file__).resolve().parents[1] / "scripts/build.py")
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


class SigningTests(unittest.TestCase):
    first = ("A" * 40, "Apple Development: Example One")
    second = ("B" * 40, "Apple Development: Example Two")

    def test_saved_identity_survives_new_certificates(self):
        self.assertEqual(build.choose_identity([self.second, self.first], saved=self.first[0]), self.first)

    def test_missing_saved_identity_must_not_switch_to_another_certificate(self):
        with self.assertRaises(ValueError):
            build.choose_identity([self.second], saved=self.first[0])

    def test_missing_certificates_require_explicit_ad_hoc(self):
        with self.assertRaises(ValueError):
            build.choose_identity([])
        self.assertEqual(build.choose_identity([], ad_hoc=True)[0], "-")

    def test_ambiguous_default_and_name_require_explicit_choice(self):
        with self.assertRaises(ValueError):
            build.choose_identity([self.first, self.second])
        with self.assertRaises(ValueError):
            build.choose_identity([self.first, (self.second[0], self.first[1])], requested=self.first[1])

    def test_explicit_identity_overrides_saved_identity(self):
        self.assertEqual(build.choose_identity([self.first, self.second], requested=self.second[0].lower(), saved=self.first[0]), self.second)
        self.assertEqual(build.choose_identity([self.first], requested=self.first[1]), self.first)

    def test_single_identity_can_be_selected(self):
        self.assertEqual(build.choose_identity([self.first]), self.first)

    def test_ad_hoc_cannot_replace_saved_certificate(self):
        with self.assertRaises(ValueError):
            build.choose_identity([], saved=self.first[0], ad_hoc=True)

    def test_ad_hoc_cannot_override_configured_identity(self):
        with self.assertRaises(ValueError):
            build.choose_identity([], requested=self.first[0], ad_hoc=True)


if __name__ == "__main__":
    unittest.main()
