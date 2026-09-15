import unittest
from unittest.mock import patch

from agent import nature_agent


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


if __name__ == "__main__":
    unittest.main()
