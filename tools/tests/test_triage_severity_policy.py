"""Guard the automatic severity writer's scope and override boundary."""

import json
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]


class TriageSeverityPolicyTests(unittest.TestCase):
    def test_only_automatic_labels_are_writable(self):
        workflow = (ROOT / ".github/workflows/issue-triage.md").read_text()
        frontmatter = workflow.split("---", 2)[1]
        grants = re.findall(r'allowed: (\["triage:.*\])', frontmatter)
        self.assertEqual(len(grants), 2)
        expected = {"triage: needs evidence", "triage: investigate", "triage: verify",
                    "triage: backlog", "severity: blocking", "severity: major", "severity: normal"}
        for grant in grants:
            self.assertEqual(set(json.loads(grant)), expected)
        self.assertNotIn("severity override:", frontmatter)
        self.assertIn("max-labels: 2", frontmatter)
        self.assertIn("schema_version: 3", workflow)
        self.assertIn("no practical workaround", workflow)
        self.assertIn("not a blocker", workflow)
        self.assertIn('args: ["--reasoning-effort", "high"]', frontmatter)
        self.assertIn("model: gpt-6.1-sol", frontmatter)


if __name__ == "__main__":
    unittest.main()
