import importlib.util
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).parents[2] / "cli" / "the_notch.py"
spec = importlib.util.spec_from_file_location("the_notch", MODULE_PATH)
the_notch = importlib.util.module_from_spec(spec)
assert spec.loader
sys.modules[spec.name] = the_notch
spec.loader.exec_module(the_notch)


class TheNotchCLITests(unittest.TestCase):
    def test_parse_usage_prefers_account_bucket_and_preserves_windows(self):
        windows, plan_type = the_notch.parse_usage_result(
            {
                "rateLimits": {
                    "limitId": "codex",
                    "limitName": "Codex",
                    "primary": {"usedPercent": 42, "windowDurationMins": 300, "resetsAt": 1_800_000_000},
                    "secondary": {"usedPercent": 18, "windowDurationMins": 10_080, "resetsAt": 1_800_600_000},
                },
                "rateLimitsByLimitId": {
                    "gpt-5": {"primary": {"usedPercent": 99, "windowDurationMins": 60, "resetsAt": 1_800_000_000}}
                },
            }
        )
        self.assertEqual([window.role for window in windows], ["primary", "secondary"])
        self.assertEqual(windows[0].name, "5-hour window · Codex")
        self.assertEqual(windows[1].duration_minutes, 10_080)
        self.assertEqual(plan_type, None)

    def test_pace_and_projection_use_recorded_history(self):
        now = time.time()
        window = the_notch.Window("codex.primary", "5-hour window", "primary", 70, 300, now + 2 * 3600)
        history = [
            {"observedAt": now - 3600, "windows": [{"id": window.id, "usedPercent": 40}]},
        ]
        payload = the_notch.window_payload(window, history, now)
        self.assertAlmostEqual(payload["changePercentPerHour"], 30.0, places=2)
        self.assertGreater(payload["projectedUsageAtResetPercent"], 90)
        self.assertEqual(payload["status"], "ahead_of_pace")

    def test_recommendation_never_applies_automatic_actions(self):
        payload = {
            "windows": [
                {
                    "name": "Weekly window",
                    "paceDeltaPercent": 12,
                    "projectedUsageAtResetPercent": 105,
                }
            ]
        }
        recommendation = the_notch.recommendation(payload)
        self.assertEqual(recommendation["mode"], "conservative")
        self.assertEqual(recommendation["recommendedConcurrency"], 1)
        self.assertFalse(recommendation["automaticActionTaken"])

    def test_banked_reset_data_is_explicitly_unknown(self):
        payload = the_notch.status_payload([], None, record=False)
        self.assertIsNone(payload["resets"]["bankedCount"])
        self.assertEqual(payload["resets"]["bankedStatus"], "unknown")

    def test_record_is_explicit_and_local(self):
        with tempfile.TemporaryDirectory() as directory:
            original = the_notch.HISTORY_PATH
            the_notch.HISTORY_PATH = Path(directory) / "usage-history.jsonl"
            try:
                window = the_notch.Window("codex.primary", "Weekly window", "primary", 10, 10_080, time.time() + 3600)
                payload = the_notch.status_payload([window], None, record=True)
                self.assertTrue(payload["historyRecorded"])
                self.assertTrue(the_notch.HISTORY_PATH.exists())
                self.assertEqual(len(the_notch.read_history()), 1)
            finally:
                the_notch.HISTORY_PATH = original

    def test_fetch_usage_speaks_json_rpc_to_codex_app_server(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "fake-codex"
            executable.write_text(
                "#!/usr/bin/env python3\n"
                "import json, sys\n"
                "for line in sys.stdin:\n"
                "    message = json.loads(line)\n"
                "    if message.get('id') == 2:\n"
                "        print(json.dumps({'id': 2, 'result': {'rateLimits': {'planType': 'test', 'primary': {'usedPercent': 12, 'windowDurationMins': 300, 'resetsAt': 1800000000}}}}), flush=True)\n"
            )
            executable.chmod(0o755)
            original_path = os.environ.get("THE_NOTCH_CODEX_PATH")
            os.environ["THE_NOTCH_CODEX_PATH"] = str(executable)
            try:
                windows, plan_type = the_notch.fetch_usage(timeout=1)
            finally:
                if original_path is None:
                    os.environ.pop("THE_NOTCH_CODEX_PATH", None)
                else:
                    os.environ["THE_NOTCH_CODEX_PATH"] = original_path
            self.assertEqual(plan_type, "test")
            self.assertEqual(windows[0].used_percent, 12)


if __name__ == "__main__":
    unittest.main()
