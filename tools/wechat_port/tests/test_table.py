import json
import os
import tempfile
import unittest

from wechat_port.table import (
    SNS_ADAPTATION_KEYS,
    SNS_CORE_BODY_RETURN_KEYS,
    VersionTable,
    diff_tables,
    is_address_key,
    key_kind,
    render_template,
    sns_coverage,
    sns_missing_keys,
    template_key_sets,
    validate_table,
)


class TableTests(unittest.TestCase):
    def make_table(self, data):
        fd, path = tempfile.mkstemp(suffix=".json")
        os.close(fd)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(data, fh)
        self.addCleanup(os.unlink, path)
        return VersionTable.load(path)

    def test_address_classification(self):
        self.assertTrue(is_address_key("sendFuncAddr", "0x12345"))
        self.assertTrue(is_address_key("defaultScopeString", "0x12345"))
        self.assertFalse(is_address_key("newSendMsgTaskSize", "0xe0"))
        self.assertFalse(is_address_key("messageContentOffset", "0x118"))
        self.assertEqual(key_kind("sendFuncAddr", "0x12345"), "function")
        self.assertEqual(key_kind("messageVtable", "0x12345"), "vtable")
        self.assertEqual(key_kind("snsTimelineCtor", "0x12345"), "ctor")
        self.assertEqual(key_kind("snsTimelineDecoder", "0x12345"), "decoder")
        self.assertEqual(key_kind("snsTimelineBodyReturn", "0x12345"), "body_return")

    def test_render_template(self):
        table = self.make_table({"a": "0x10", "flag": "true"})
        source = 'var a = "{{.a}}"; {{if .flag}}var b = "{{.b}}";{{end}}'
        rendered = render_template(source, table)
        self.assertEqual(rendered, 'var a = "0x10"; var b = "<no value>";')

    def test_required_template_keys(self):
        source = '{{.required}} {{if .conditional}}x{{end}} {{.snsTimelineCtor}}'
        all_keys, required, optional = template_key_sets(source)
        self.assertEqual(all_keys, {"required", "conditional", "snsTimelineCtor"})
        self.assertIn("required", required)
        self.assertIn("snsTimelineCtor", optional)

    def test_validate_reports_bad_offsets(self):
        table = self.make_table({
            "hookVerified": "false",
            "messageContentOffset": "0x118",
            "snsTimelineBodyReturn": "0x1001",
        })
        errors = validate_table(table)
        self.assertTrue(any("pair" in error for error in errors))
        self.assertTrue(any("aligned" in error for error in errors))

    def sns_data(self, *, drop=()):
        data = {"hookVerified": "false"}
        for prefix in ("snsTimeline", "snsSync", "snsPost", "snsUserpage", "snsComment"):
            for suffix in ("Ctor", "Vtable", "Size", "ClosureVtable", "Decoder"):
                data[prefix + suffix] = "0x1000" if suffix == "Size" else "0x10000"
        for key in ("snsTimelineBodyReturn", "snsSyncBodyReturn",
                    "snsPostBodyReturn", "snsCommentBodyReturn"):
            data[key] = "0x20000"
        for key in drop:
            data.pop(key, None)
        return data

    def test_sns_coverage_complete(self):
        table = self.make_table(self.sns_data())
        summary = sns_coverage(table.data)
        self.assertTrue(summary["capable"])
        self.assertTrue(summary["complete"])
        self.assertEqual(summary["missing"], [])
        self.assertEqual(len(SNS_ADAPTATION_KEYS), 29)

    def test_sns_missing_detects_partial_group_and_body_returns(self):
        table = self.make_table(self.sns_data(drop=("snsPostCtor", "snsSyncBodyReturn")))
        missing = sns_missing_keys(table.data)
        self.assertIn("snsPostCtor", missing)
        self.assertIn("snsSyncBodyReturn", missing)
        self.assertTrue(any("anchor group incomplete" in error for error in validate_table(table)))

    def test_sns_absent_table_is_not_flagged(self):
        table = self.make_table({"hookVerified": "false"})
        self.assertFalse(sns_coverage(table.data)["capable"])
        self.assertEqual(sns_missing_keys(table.data), [])
        self.assertEqual(validate_table(table), [])

    def test_sns_comment_body_return_is_optional_for_legacy_tables(self):
        # 4.2.0.17 没有评论模板返回点：三件套齐全时不能报错。
        table = self.make_table(self.sns_data(drop=("snsCommentBodyReturn",)))
        self.assertEqual(validate_table(table), [])
        self.assertEqual(sns_missing_keys(table.data), [])
        self.assertTrue(all(key in table.data for key in SNS_CORE_BODY_RETURN_KEYS))

    def test_diff(self):
        old = self.make_table({"a": "0x1", "b": "0x2"})
        new = self.make_table({"a": "0x1", "b": "0x3", "c": "0x4"})
        rows = diff_tables(old, new)
        self.assertEqual({row["key"] for row in rows}, {"b", "c"})


if __name__ == "__main__":
    unittest.main()
