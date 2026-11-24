import json
import os
import tempfile
import unittest

from wechat_port.table import (
    VersionTable,
    diff_tables,
    is_address_key,
    key_kind,
    render_template,
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

    def test_diff(self):
        old = self.make_table({"a": "0x1", "b": "0x2"})
        new = self.make_table({"a": "0x1", "b": "0x3", "c": "0x4"})
        rows = diff_tables(old, new)
        self.assertEqual({row["key"] for row in rows}, {"b", "c"})


if __name__ == "__main__":
    unittest.main()
