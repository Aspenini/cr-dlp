#!/usr/bin/env python3
"""Export the pinned Python implementation's public compatibility metadata."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
DEFAULT_SOURCE_REF = 'acf8ab7a6'


def normalize(value):
    if value == ('NO', 'DEFAULT'):
        return None
    if isinstance(value, dict):
        return {str(key): normalize(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [normalize(item) for item in value]
    if isinstance(value, (set, frozenset)):
        return sorted(normalize(item) for item in value)
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    if isinstance(value, type):
        return {'$type': value.__name__}
    return {'$repr': repr(value)}


def export_options():
    from yt_dlp.options import create_parser

    parser = create_parser()
    definitions = []
    groups = [('General', parser.option_list)]
    groups.extend((group.title, group.option_list) for group in parser.option_groups)
    for group, options in groups:
        for option in options:
            flags = [*option._short_opts, *option._long_opts]
            if not flags:
                continue
            callback = getattr(option.callback, '__name__', None)
            definitions.append({
                'flags': flags,
                'dest': option.dest,
                'action': option.action,
                'type': option.type,
                'default': normalize(option.default),
                'const': normalize(option.const),
                'metavar': option.metavar,
                'help': option.help,
                'group': group,
                'callback': callback,
                'takes_value': option.takes_value(),
            })
    return definitions


def export_extractors(include_tests):
    os.environ['YTDLP_NO_PLUGINS'] = '1'
    os.environ['YTDLP_NO_LAZY_EXTRACTORS'] = '1'
    from yt_dlp.extractor import gen_extractor_classes

    result = []
    for extractor in gen_extractor_classes():
        tests = list(extractor.get_testcases(include_onlymatching=True))
        entry = {
            'key': extractor.ie_key(),
            'name': extractor.IE_NAME,
            'class': extractor.__name__,
            'module': extractor.__module__,
            'valid_url': normalize(extractor._VALID_URL),
            'working': bool(extractor.working()),
            'test_count': len(tests),
        }
        if include_tests:
            entry['tests'] = normalize(tests)
        result.append(entry)
    return result


def export_extractor_tests():
    os.environ['YTDLP_NO_PLUGINS'] = '1'
    os.environ['YTDLP_NO_LAZY_EXTRACTORS'] = '1'
    from yt_dlp.extractor import gen_extractor_classes

    result = []
    for extractor in gen_extractor_classes():
        tests = list(extractor.get_testcases(include_onlymatching=True))
        webpage_tests = list(extractor.get_webpage_testcases())
        if not tests and not webpage_tests:
            continue
        result.append({
            'key': extractor.ie_key(),
            'tests': normalize(tests),
            'webpage_tests': normalize(webpage_tests),
        })
    return result


def export_protocols():
    from yt_dlp.downloader import PROTOCOL_MAP

    return {
        key: value.__name__
        for key, value in sorted(PROTOCOL_MAP.items())
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        '--output',
        type=Path,
        default=ROOT / 'baseline' / 'crystal',
    )
    parser.add_argument('--source-ref', default=DEFAULT_SOURCE_REF)
    parser.add_argument('--include-tests', action='store_true')
    args = parser.parse_args()

    commit = subprocess.check_output(
        ['git', 'rev-parse', '--short=10', args.source_ref],
        cwd=ROOT,
        text=True,
    ).strip()
    output = args.output
    output.mkdir(parents=True, exist_ok=True)

    options = export_options()
    extractors = export_extractors(args.include_tests)
    extractor_tests = export_extractor_tests()
    documents = {
        'options.json': options,
        'extractors.json': extractors,
        'extractor_tests.json': extractor_tests,
        'protocols.json': export_protocols(),
        'manifest.json': {
            'source_commit': commit,
            'option_count': len(options),
            'extractor_count': len(extractors),
            'extractor_test_suites': len(extractor_tests),
            'extractor_test_cases': sum(
                len(entry['tests']) + len(entry['webpage_tests'])
                for entry in extractor_tests
            ),
        },
    }
    for filename, document in documents.items():
        (output / filename).write_text(
            json.dumps(document, indent=2, sort_keys=True) + '\n',
            encoding='utf-8',
        )


if __name__ == '__main__':
    main()
