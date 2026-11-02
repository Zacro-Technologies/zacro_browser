#!/usr/bin/env python3
"""Receipt validator regressions; synthetic files are never runnable runtimes."""
import importlib.util
import json
import pathlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("validate_runtime", pathlib.Path(__file__).with_name("validate-runtime.py"))
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class RuntimeReceiptTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="zacro-runtime-receipt-")
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.inputs = self.root / "inputs"
        self.inputs.mkdir()
        (self.inputs / "adapter.inc").write_text("fixture source\n")
        self.framework = self.root / "Chromium Embedded Framework.framework"
        (self.framework / "Libraries").mkdir(parents=True)
        (self.framework / "Resources").mkdir()
        self.binary = self.framework / "Chromium Embedded Framework"
        self.binary.write_bytes(b"synthetic test bytes, not a Mach-O executable")
        (self.framework / "Libraries/libcef_sandbox.dylib").write_bytes(b"fixture sandbox")
        (self.framework / "Resources/icudtl.dat").write_bytes(b"fixture ICU data")
        self.receipt = self.root / "receipt.json"
        (self.root / "args.gn").write_text('target_cpu="arm64"\n')
        self.record = {
            "chromium": "156.0.8078.48", "chromiumCommit": runtime.CHROMIUM_COMMIT,
            "cefCommit": runtime.CEF_COMMIT, "nativeInputs": runtime.native_inputs(self.inputs),
            "gnArgsSha256": runtime.digest(self.root / "args.gn"), "framework": str(self.framework),
            "sha256": runtime.digest(self.binary), "symlinks": {},
            "files": {p.relative_to(self.framework).as_posix(): runtime.digest(p)
                      for p in self.framework.rglob("*") if p.is_file()},
        }
        self.save()

    def save(self):
        self.receipt.write_text(json.dumps(self.record))

    def validate(self):
        return runtime.validate(self.receipt, input_root=self.inputs, check_architecture=False)

    def test_matching_receipt_does_not_mutate_source(self):
        framework, record = self.validate()
        self.assertEqual(framework, self.framework.resolve())
        self.assertEqual(record, self.record)
        self.assertFalse((self.framework / "Versions").exists())

    def test_changed_source_requires_rebuild(self):
        (self.inputs / "adapter.inc").write_text("new fixture source")
        with self.assertRaisesRegex(ValueError, "sources changed"):
            self.validate()

    def test_changed_framework_binary_is_rejected(self):
        self.binary.write_bytes(b"another binary")
        with self.assertRaisesRegex(ValueError, "binary changed"):
            self.validate()

    def test_changed_or_added_resource_is_rejected(self):
        (self.framework / "Resources/extra.pak").write_bytes(b"unexpected")
        with self.assertRaisesRegex(ValueError, "resources"):
            self.validate()

    def test_external_symlink_is_rejected(self):
        (self.framework / "Resources/escape").symlink_to(self.inputs)
        with self.assertRaisesRegex(ValueError, "outside"):
            self.validate()

    def test_unrecorded_internal_symlink_is_rejected(self):
        (self.framework / "Resources/alias").symlink_to("icudtl.dat")
        with self.assertRaisesRegex(ValueError, "links"):
            self.validate()

    def test_stock_or_incomplete_receipt_is_rejected(self):
        self.record.pop("nativeInputs")
        self.save()
        with self.assertRaises(ValueError):
            self.validate()

    def test_wrong_revision_is_rejected(self):
        self.record["chromiumCommit"] = "0" * 40
        self.save()
        with self.assertRaisesRegex(ValueError, "revisions"):
            self.validate()

    def test_changed_build_arguments_require_rebuild(self):
        (self.root / "args.gn").write_text('target_cpu="x64"\n')
        with self.assertRaisesRegex(ValueError, "build arguments changed"):
            self.validate()


if __name__ == "__main__":
    unittest.main()
