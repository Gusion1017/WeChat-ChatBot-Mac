import os
import unittest

from wechat_port.cli import sns_adaptation_summary
from wechat_port.registry import scan
from wechat_port.table import VersionTable, sns_coverage

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))


def table(name):
    return VersionTable.load(os.path.join(ROOT, "hook", "versions", name + "_mac.json"))


class SNSAdaptationTests(unittest.TestCase):
    def test_complete_version_passes(self):
        summary, errors = sns_adaptation_summary(table("4_2_1_3"), table("4_2_1_5"))
        self.assertEqual(errors, [])
        self.assertTrue(summary["capable"])
        self.assertTrue(summary["candidate_complete"])
        self.assertEqual(summary["missing_vs_baseline"], [])

    def test_dropped_post_anchors_are_rejected(self):
        baseline = table("4_2_1_3")
        data = dict(table("4_2_1_5").data)
        for key in list(data):
            if key.startswith("snsPost"):
                del data[key]
        import tempfile, json
        fd, path = tempfile.mkstemp(suffix=".json")
        os.close(fd)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(data, fh)
        self.addCleanup(os.unlink, path)
        summary, errors = sns_adaptation_summary(baseline, VersionTable.load(path))
        self.assertTrue(errors)
        self.assertIn("snsPostCtor", summary["missing_vs_baseline"])
        self.assertFalse(summary["candidate_complete"])

    def test_non_sns_baseline_is_not_constrained(self):
        summary, errors = sns_adaptation_summary(table("4_2_0_5"), table("4_2_0_5"))
        self.assertEqual(errors, [])
        self.assertFalse(summary["capable"])

    def test_registration_requires_sns_anchors(self):
        result = scan(ROOT, "4.2.1.5", "270597")
        sns_checks = [item for item in result["checks"] if item["category"] == "sns_read_write"]
        self.assertTrue(sns_checks)
        self.assertTrue(all(item["ok"] for item in sns_checks),
                        [item for item in sns_checks if not item["ok"]])

    def test_legacy_table_has_no_body_return_requirement(self):
        # 4.2.0.17 缺 snsCommentBodyReturn：不算不完整（评论退回自拼报文）。
        coverage = sns_coverage(table("4_2_0_17").data)
        self.assertTrue(coverage["capable"])
        self.assertTrue(coverage["complete"])


if __name__ == "__main__":
    unittest.main()
