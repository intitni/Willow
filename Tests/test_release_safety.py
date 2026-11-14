import importlib.util
import pathlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('release_safety', pathlib.Path(__file__).resolve().parents[1] / 'Scripts/check-release-safety.py')
safety = importlib.util.module_from_spec(spec)
spec.loader.exec_module(safety)


class ReleaseSafetyTests(unittest.TestCase):
    def check(self, name, content):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / name
            path.write_text(content)
            return safety.file_issues(path)

    def test_optional_local_config_is_safe(self):
        self.assertFalse(self.check('Signing.xcconfig', 'DEVELOPMENT_TEAM =\n#include? "Signing.local.xcconfig"\n'))

    def test_personal_team_and_profiles_are_rejected(self):
        self.assertTrue(self.check('project.pbxproj', '\tDEVELOPMENT_TEAM = TESTTEAM01;\n'))
        self.assertTrue(self.check('profile.mobileprovision', 'fixture'))
        self.assertTrue(self.check('Signing.local.xcconfig', ''))

    def test_private_material_is_rejected_under_an_innocent_filename(self):
        marker = '-----BEGIN ' + 'PRIVATE KEY-----'
        self.assertTrue(self.check('notes.txt', marker))

    def test_build_setting_variables_are_allowed(self):
        self.assertFalse(self.check('Signing.xcconfig', 'DEVELOPMENT_TEAM = $(LOCAL_TEAM)\n'))


if __name__ == '__main__':
    unittest.main()
