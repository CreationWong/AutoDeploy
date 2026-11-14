"""验证词典格式、英文回退以及不执行动态文本。"""
import os
from pathlib import Path
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
LIBRARY = ROOT / 'src/scripts/autodeploy-i18n'

class I18nTests(unittest.TestCase):
    def translate(self, language, message, *args):
        env = dict(os.environ, AUTODEPLOY_LANG=language)
        return subprocess.run(['bash', '-c', '. "$1"; shift; autodeploy_msg "$@"',
                               'test', str(LIBRARY), message, *args], env=env,
                              text=True, capture_output=True, check=True).stdout

    def test_default_and_fallback(self):
        for language in ('', 'en', 'fr', '../../tmp'):
            self.assertEqual(self.translate(language, 'Deployment complete: %s (%s)', 'app', 'process'),
                             'Deployment complete: app (process)')
        self.assertEqual(self.translate('zh', 'An untranslated message'), 'An untranslated message')

    def test_chinese_interpolation_and_literal_values(self):
        value = '应用 %s $(echo unexpected) `uname` \\n'
        for language in ('zh', 'zh_CN.UTF-8', 'zh-CN'):
            self.assertEqual(self.translate(language, 'Deployment complete: %s (%s)', value, 'process'),
                             f'部署完成: {value} (process)')

    def test_catalog_format_parity(self):
        # 每条中英翻译必须保留相同的 printf/Git 占位符及顺序。
        source = LIBRARY.read_text()
        entries = re.findall(r"'([^']*)'\) message='([^']*)' ;;", source, re.S)
        self.assertGreater(len(entries), 150)
        for english, chinese in entries:
            with self.subTest(message=english):
                pattern = r'%[-.0-9]*[A-Za-z]+'
                self.assertEqual(re.findall(pattern, english), re.findall(pattern, chinese))

    def test_runtime_messages_are_not_hardcoded_chinese(self):
        for path in [ROOT / 'src/entrypoint.sh', *(ROOT / 'src/scripts').iterdir()]:
            if path == LIBRARY:
                continue
            for number, line in enumerate(path.read_text().splitlines(), 1):
                if not line.lstrip().startswith('#'):
                    self.assertIsNone(re.search(r'[\u4e00-\u9fff]', line), f'{path}:{number}')
