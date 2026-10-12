import importlib.util,pathlib,tempfile,unittest
ROOT=pathlib.Path(__file__).resolve().parents[1]
class SmokeTests(unittest.TestCase):
 def test_rejects_unpinned_revision(self):
  spec=importlib.util.spec_from_file_location('smoke',ROOT/'bin/fm-repro-smoke.py')
  module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
  with self.assertRaises(ValueError): module.validate_revision('HEAD')
if __name__=='__main__': unittest.main()
