import os
import unittest

from wechat_port.image import Image
from wechat_port.table import VersionTable
from wechat_port.resolver import Resolver

FIXTURES = os.environ.get("WECHAT_PORT_FIXTURES")


@unittest.skipUnless(FIXTURES, "set WECHAT_PORT_FIXTURES to the fixture directory")
class BacktestIntegration(unittest.TestCase):
    def test_minor_update_backtest(self):
        root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
        old_table = VersionTable.load(os.path.join(root, "hook/versions/4_2_0_12_mac.json"))
        truth = VersionTable.load(os.path.join(root, "hook/versions/4_2_0_17_mac.json"))
        old = Image(os.path.join(FIXTURES, "wechat-4.2.0.12-arm64.dylib"))
        new = Image(os.path.join(FIXTURES, "wechat-4.2.0.17-arm64.dylib"))
        try:
            resolver = Resolver(old, new, old_table)
            results = resolver.resolve_all()
            matched = 0
            for key, result in results.items():
                expected = truth.hex_value(key)
                if expected is not None and result.new == expected:
                    matched += 1
            total = sum(1 for key in results if truth.hex_value(key) is not None)
            self.assertEqual(matched, total)
        finally:
            old.close()
            new.close()


if __name__ == "__main__":
    unittest.main()
