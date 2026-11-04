#!/usr/bin/env python3
"""Pure report/driver regressions; mocked launch only, no browser or compiler."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS))
try:
    spec = importlib.util.spec_from_file_location("zacro_check_app_report", SCRIPTS / "check-app.py")
    driver = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(driver)
finally:
    sys.path.pop(0)


class AcceptanceReportTests(unittest.TestCase):
    def report(self, suite="all"):
        return {"passed": True, "suite": suite, "fullApplicationSuitePassed": suite == "all",
                "checks": {"actualNativeOwner": True}, "nativeExtensionProtocol": True,
                "extensionFixturePassed": True, "extensionCompatibilityVerified": False}

    def validate(self, report, suite="all", required=True):
        driver.validate_acceptance_report(report, integration=True, suite=suite,
                                          require_extensions=required)

    def test_valid_full_native_fixture_keeps_bounded_compatibility_reporting(self):
        self.validate(self.report())

    def test_full_report_requires_explicit_matching_suite(self):
        for value in [None, "extensions", "history-mirror", ""]:
            report = self.report()
            if value is None:
                report.pop("suite")
            else:
                report["suite"] = value
            with self.subTest(value=value), self.assertRaisesRegex(driver.AcceptanceReportError, "requested application suite"):
                self.validate(report)

    def test_full_report_requires_explicit_true_full_receipt(self):
        for value in [None, False, 1, "true", "false", [], {}]:
            report = self.report()
            if value is None:
                report.pop("fullApplicationSuitePassed")
            else:
                report["fullApplicationSuitePassed"] = value
            with self.subTest(value=value), self.assertRaisesRegex(driver.AcceptanceReportError, "full or focused"):
                self.validate(report)

    def test_focused_extensions_fixture_cannot_claim_full_application(self):
        self.validate(self.report("extensions"), suite="extensions")
        for value in [None, True, 0, "false"]:
            report = self.report("extensions")
            if value is None:
                report.pop("fullApplicationSuitePassed")
            else:
                report["fullApplicationSuitePassed"] = value
            with self.subTest(value=value), self.assertRaisesRegex(driver.AcceptanceReportError, "full or focused"):
                self.validate(report, suite="extensions")

    def test_focused_nonextension_scope_remains_valid_without_mv3_marker(self):
        report = self.report("history-publication")
        report["extensionFixturePassed"] = False
        self.validate(report, suite="history-publication", required=False)

    def test_missing_empty_or_nonobject_checks_are_rejected(self):
        for value in [None, {}, [], True, "checks"]:
            report = self.report()
            if value is None:
                report.pop("checks")
            else:
                report["checks"] = value
            with self.subTest(value=value), self.assertRaisesRegex(driver.AcceptanceReportError, "no valid checks"):
                self.validate(report)

    def test_false_and_nonboolean_checks_are_not_success(self):
        for value in [False, 0, 1, None, "true", "false", [], {}]:
            report = self.report(); report["checks"]["actualNativeOwner"] = value
            with self.subTest(value=value), self.assertRaisesRegex(driver.AcceptanceReportError, "failed or nonboolean"):
                self.validate(report)

    def test_all_checks_and_names_are_validated(self):
        for checks in [{"good": True, "bad": False}, {"": True}, {1: True}]:
            report = self.report(); report["checks"] = checks
            with self.subTest(checks=checks), self.assertRaises(driver.AcceptanceReportError):
                self.validate(report)

    def test_native_protocol_and_real_fixture_gates_remain_required(self):
        for key in ["nativeExtensionProtocol", "extensionFixturePassed"]:
            for value in [None, False, 1, "true"]:
                report = self.report()
                if value is None:
                    report.pop(key)
                else:
                    report[key] = value
                with self.subTest(key=key, value=value), self.assertRaisesRegex(driver.AcceptanceReportError, "real extension fixture"):
                    self.validate(report)

    def test_explicit_stock_application_diagnostic_does_not_claim_extension_fixture(self):
        report = self.report(); report["nativeExtensionProtocol"] = False; report["extensionFixturePassed"] = False
        self.validate(report, required=False)

    def test_engine_nonintegration_report_compatibility_is_unchanged(self):
        driver.validate_acceptance_report({"passed": True})
        driver.validate_acceptance_report({"passed": True, "checks": ["older engine representation"]})

    def test_scoped_accessibility_contract_is_preserved(self):
        report = {"passed": True, "suite": "accessibility", "fullEngineSuitePassed": False}
        driver.validate_acceptance_report(report, accessibility=True)
        for key, value in [("suite", "all"), ("fullEngineSuitePassed", True), ("fullEngineSuitePassed", 0)]:
            wrong = dict(report); wrong[key] = value
            with self.subTest(key=key, value=value), self.assertRaisesRegex(driver.AcceptanceReportError, "scoped AX"):
                driver.validate_acceptance_report(wrong, accessibility=True)

    def test_failed_report_and_nonobject_payload_cannot_pass(self):
        for value in [False, 1, "true", None]:
            report = self.report(); report["passed"] = value; report["error"] = "exact owned failure"
            with self.subTest(value=value), self.assertRaisesRegex(driver.AcceptanceReportError, "exact owned failure"):
                self.validate(report)
        for value in [None, [], True]:
            with self.subTest(value=value), self.assertRaisesRegex(driver.AcceptanceReportError, "not an object"):
                driver.validate_acceptance_report(value)

    def test_extension_requirement_cannot_certify_engine_only_run(self):
        with self.assertRaisesRegex(driver.AcceptanceReportError, "requires application integration"):
            driver.validate_acceptance_report(self.report(), require_extensions=True)


class MockedRunGateTests(unittest.TestCase):
    def run_driver(self, exit_code):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "Fixture.app"
            executable = app / "Contents/MacOS/Zacro Native"
            executable.parent.mkdir(parents=True); executable.write_bytes(b"not executed")
            output = root / "reports"
            result = AcceptanceReportTests().report()
            profile = mock.MagicMock()
            profile.__enter__.return_value = str(root / "owned-profile")
            profile.__exit__.return_value = False
            process = mock.MagicMock()
            def finish(**_):
                (output / "application.json").write_text(json.dumps(result))
                return exit_code
            process.wait.side_effect = finish
            server = mock.MagicMock(); server.server_port = 12345
            with mock.patch.object(driver, "AcceptanceProfile", return_value=profile), \
                 mock.patch.object(driver, "build_host", return_value=root / "not-launched-native-host"), \
                 mock.patch.object(driver, "LoopbackTURN"), \
                 mock.patch.object(driver.http.server, "ThreadingHTTPServer", return_value=server), \
                 mock.patch.object(driver.threading, "Thread"), \
                 mock.patch.object(driver.subprocess, "Popen", return_value=process) as launch, \
                 mock.patch.dict(os.environ, {"TMPDIR": str(root)}), \
                 mock.patch.object(sys, "argv", ["check-app.py", "--app", str(app), "--output", str(output),
                                                  "--integration", "--require-extensions"]), \
                 contextlib.redirect_stdout(io.StringIO()) as stdout:
                driver.main()
                self.assertEqual(launch.call_count, 1)
                self.assertIn("application ownership", stdout.getvalue())

    def test_clean_mocked_exit_and_valid_full_report_pass(self):
        self.run_driver(0)

    def test_success_report_cannot_hide_nonzero_actual_exit(self):
        with self.assertRaisesRegex(SystemExit, "application exited with 17"):
            self.run_driver(17)


if __name__ == "__main__":
    unittest.main()
