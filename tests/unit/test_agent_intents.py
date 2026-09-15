import unittest
from unittest.mock import patch

from agent import nature_agent
from agent import model_manager


class DirectIntentTests(unittest.TestCase):
    def test_explicit_recursive_windows_drive_scan_is_not_delegated_to_model(self) -> None:
        with patch.object(nature_agent, "_packs", return_value={"core"}), patch.object(
            nature_agent,
            "execute_tool",
            return_value={
                "status": "verified",
                "root": "F:\\",
                "recursive": True,
                "folders": [{"path": "F:\\example"}],
                "count": 1,
                "truncated": False,
                "display_truncated": False,
                "errors": [],
            },
        ) as execute:
            response = nature_agent.handle_message(
                "Scan my F drive and list every single folder I currently have under the drive.",
                "test-model",
            )

        execute.assert_called_once()
        name, arguments = execute.call_args.args
        self.assertEqual(name, "list_windows_directories")
        self.assertEqual(arguments["path"], "F:\\")
        self.assertTrue(arguments["recursive"])
        self.assertIn("WINDOWS_FILESYSTEM_SCAN_OK", response["choices"][0]["message"]["content"])

    def test_explicit_chrome_request_uses_host_launch_receipt(self) -> None:
        with patch.object(nature_agent, "_packs", return_value={"core"}), patch.object(
            nature_agent,
            "execute_tool",
            return_value={
                "status": "opened-requested",
                "browser": "chrome",
                "url": "https://www.youtube.com/",
                "new_tab": True,
                "observed": False,
                "controlled": False,
                "process_id": 1,
            },
        ) as execute:
            response = nature_agent.handle_message(
                "Open my default Chrome browser and open YouTube in a new tab.",
                "test-model",
            )

        execute.assert_called_once()
        name, arguments = execute.call_args.args
        self.assertEqual(name, "open_default_browser")
        self.assertEqual(arguments["url"], "https://www.youtube.com/")
        self.assertTrue(arguments["new_tab"])
        self.assertIn("BROWSER_OPEN_REQUESTED", response["choices"][0]["message"]["content"])

    def test_plain_url_open_uses_the_requested_host_launch_without_browser_pack(self) -> None:
        with patch.object(nature_agent, "_packs", return_value={"core"}), patch.object(
            nature_agent,
            "execute_tool",
            return_value={"status": "opened-requested", "browser": "chrome", "url": "https://example.com/", "new_tab": True},
        ) as execute:
            response = nature_agent.handle_message("Open https://example.com in a new tab.", "test-model")

        execute.assert_called_once()
        name, arguments = execute.call_args.args
        self.assertEqual(name, "open_default_browser")
        self.assertEqual(arguments["url"], "https://example.com")
        self.assertIn("BROWSER_OPEN_REQUESTED", response["choices"][0]["message"]["content"])

    def test_model_manager_requires_one_explicit_candidate_when_lock_grows(self) -> None:
        lock = {"models": [{"id": "fast", "profiles": ["fast"]}, {"id": "quality", "profiles": ["quality"]}]}
        with patch.dict("os.environ", {"MODEL_ID": "quality"}, clear=False):
            self.assertEqual(model_manager.selected_models(lock)[0]["id"], "quality")
        with patch.dict("os.environ", {"MODEL_ID": "", "MODEL_PROFILE": "quality"}, clear=False):
            self.assertEqual(model_manager.selected_models(lock)[0]["id"], "quality")


if __name__ == "__main__":
    unittest.main()
