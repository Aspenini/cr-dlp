#!/usr/bin/env python3
"""Small black-box differential runner for the Crystal migration."""

from __future__ import annotations

import argparse
import json
import os
import socketserver
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class FixtureHandler(BaseHTTPRequestHandler):
    direct_payload = b'cr-dlp differential fixture\n'
    cookie_payload = b'authenticated cookie fixture\n'
    routes = {
        '/fixture.mp4': ('video/mp4', direct_payload),
        '/fixture.m3u8': (
            'application/vnd.apple.mpegurl',
            b'#EXTM3U\n#EXT-X-TARGETDURATION:1\n'
            b'#EXTINF:1,\nhls-a.ts\n#EXTINF:1,\nhls-b.ts\n#EXT-X-ENDLIST\n',
        ),
        '/hls-a.ts': ('video/mp2t', b'HLS-A'),
        '/hls-b.ts': ('video/mp2t', b'HLS-B'),
        '/master.m3u8': (
            'application/vnd.apple.mpegurl',
            b'#EXTM3U\n'
            b'#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",'
            b'LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,URI="captions.vtt"\n'
            b'#EXT-X-STREAM-INF:BANDWIDTH=100000,RESOLUTION=320x180,'
            b'CODECS="avc1.4d401e,mp4a.40.2",SUBTITLES="subs"\nlow.m3u8\n'
            b'#EXT-X-STREAM-INF:BANDWIDTH=200000,RESOLUTION=640x360,'
            b'CODECS="av01.0.05M.08,mp4a.40.2",SUBTITLES="subs"\nhigh.m3u8\n',
        ),
        '/captions.vtt': (
            'text/vtt',
            b'WEBVTT\n\n00:00.000 --> 00:01.000\nDifferential subtitles\n',
        ),
        '/low.m3u8': (
            'application/vnd.apple.mpegurl',
            b'#EXTM3U\n#EXT-X-TARGETDURATION:1\n'
            b'#EXTINF:1,\nlow.ts\n#EXT-X-ENDLIST\n',
        ),
        '/high.m3u8': (
            'application/vnd.apple.mpegurl',
            b'#EXTM3U\n#EXT-X-TARGETDURATION:1\n'
            b'#EXTINF:1,\nhigh.ts\n#EXT-X-ENDLIST\n',
        ),
        '/low.ts': ('video/mp2t', b'LOW'),
        '/high.ts': ('video/mp2t', b'HIGH'),
        '/probe-master.m3u8': (
            'application/vnd.apple.mpegurl',
            b'#EXTM3U\n'
            b'#EXT-X-STREAM-INF:BANDWIDTH=100000,RESOLUTION=320x180,'
            b'CODECS="avc1.4d401e,mp4a.40.2"\nprobe-low.m3u8\n'
            b'#EXT-X-STREAM-INF:BANDWIDTH=200000,RESOLUTION=640x360,'
            b'CODECS="avc1.4d401e,mp4a.40.2"\nprobe-high.m3u8\n',
        ),
        '/probe-low.m3u8': (
            'application/vnd.apple.mpegurl',
            b'#EXTM3U\n#EXT-X-TARGETDURATION:1\n'
            b'#EXTINF:1,\nprobe-low.ts\n#EXT-X-ENDLIST\n',
        ),
        '/probe-high.m3u8': (
            'application/vnd.apple.mpegurl',
            b'#EXTM3U\n#EXT-X-TARGETDURATION:1\n'
            b'#EXTINF:1,\nprobe-missing.ts\n#EXT-X-ENDLIST\n',
        ),
        '/probe-low.ts': ('video/mp2t', b'AVAILABLE'),
        '/fixture.mpd': (
            'application/dash+xml',
            b'<?xml version="1.0"?>'
            b'<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" '
            b'mediaPresentationDuration="PT2S"><Period><AdaptationSet '
            b'contentType="video" mimeType="video/mp4" codecs="avc1.4d401e">'
            b'<Representation id="dash" bandwidth="200000" width="640" height="360">'
            b'<SegmentList><Initialization sourceURL="dash-init.mp4"/>'
            b'<SegmentURL media="dash-a.m4s"/><SegmentURL media="dash-b.m4s"/>'
            b'</SegmentList></Representation></AdaptationSet></Period></MPD>',
        ),
        '/dash-init.mp4': ('video/mp4', b'DASH-I'),
        '/dash-a.m4s': ('video/iso.segment', b'DASH-A'),
        '/dash-b.m4s': ('video/iso.segment', b'DASH-B'),
    }

    def do_GET(self):
        if self.path == '/cookie.mp4':
            if 'session=fixture' not in (self.headers.get('Cookie') or ''):
                self.send_response(403)
                self.end_headers()
                return
            self.send_response(200)
            self.send_header('Content-Type', 'video/mp4')
            self.send_header('Content-Length', str(len(self.cookie_payload)))
            self.end_headers()
            self.wfile.write(self.cookie_payload)
            return
        content_type, payload = self.routes.get(
            self.path, ('application/octet-stream', b'not found'))
        if self.path not in self.routes:
            self.send_response(404)
        else:
            self.send_response(200)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_HEAD(self):
        if self.path == '/cookie.mp4':
            authorized = 'session=fixture' in (self.headers.get('Cookie') or '')
            self.send_response(200 if authorized else 403)
            if authorized:
                self.send_header('Content-Type', 'video/mp4')
                self.send_header('Content-Length', str(len(self.cookie_payload)))
            self.end_headers()
            return
        content_type, payload = self.routes.get(
            self.path, ('application/octet-stream', b'not found'))
        self.send_response(200 if self.path in self.routes else 404)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()

    def log_message(self, *_):
        pass


class ProxyHandler(BaseHTTPRequestHandler):
    payload = b'proxied differential fixture\n'

    def _respond(self, include_body):
        self.send_response(200)
        self.send_header('Content-Type', 'video/mp4')
        self.send_header('Content-Length', str(len(self.payload)))
        self.end_headers()
        if include_body:
            self.wfile.write(self.payload)

    def do_GET(self):
        self._respond(True)

    def do_HEAD(self):
        self._respond(False)

    def log_message(self, *_):
        pass


class Socks5Handler(socketserver.BaseRequestHandler):
    payload = b'socks differential fixture\n'

    def receive(self, count):
        data = b''
        while len(data) < count:
            chunk = self.request.recv(count - len(data))
            if not chunk:
                raise EOFError('SOCKS client closed the connection')
            data += chunk
        return data

    def handle(self):
        version, method_count = self.receive(2)
        if version != 5:
            return
        self.receive(method_count)
        self.request.sendall(b'\x05\x00')

        version, command, _, address_type = self.receive(4)
        if version != 5 or command != 1:
            return
        if address_type == 1:
            self.receive(4)
        elif address_type == 3:
            self.receive(self.receive(1)[0])
        elif address_type == 4:
            self.receive(16)
        else:
            return
        self.receive(2)
        self.request.sendall(b'\x05\x00\x00\x01\x7f\x00\x00\x01\x9c\x40')

        request = b''
        while b'\r\n\r\n' not in request:
            request += self.request.recv(4096)
        method = request.partition(b' ')[0]
        response = (
            b'HTTP/1.1 200 OK\r\n'
            b'Content-Type: video/mp4\r\n'
            + f'Content-Length: {len(self.payload)}\r\n'.encode()
            + b'Connection: close\r\n\r\n'
        )
        if method != b'HEAD':
            response += self.payload
        self.request.sendall(response)


def run(command, cwd, input_text=None):
    environment = os.environ.copy()
    environment['PYTHONPATH'] = os.pathsep.join(filter(None, [
        str(ROOT),
        environment.get('PYTHONPATH'),
    ]))
    return subprocess.run(
        command,
        cwd=cwd,
        env=environment,
        text=True,
        input=input_text,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def normalized_json(stdout):
    value = json.loads(stdout.splitlines()[-1])
    for key in ('epoch', 'filename', 'filepath', 'infojson_filename'):
        value.pop(key, None)
    return value


def compare_case(binary, temporary, url, expected_bytes):
    common = ['--ignore-config', '--simulate', '--dump-single-json', url]
    python = run(['python', '-m', 'yt_dlp', *common], temporary)
    crystal = run([str(binary), *common], temporary)
    if python.returncode != crystal.returncode:
        raise SystemExit(
            f'exit mismatch for {url}: python={python.returncode}, '
            f'crystal={crystal.returncode}\npython stderr:\n{python.stderr}\n'
            f'crystal stderr:\n{crystal.stderr}'
        )
    expected = normalized_json(python.stdout)
    actual = normalized_json(crystal.stdout)
    comparable = ('id', 'title', 'ext', 'url', 'protocol')
    differences = {
        key: (expected.get(key), actual.get(key))
        for key in comparable
        if expected.get(key) != actual.get(key)
    }
    if differences:
        raise SystemExit(f'differential mismatch for {url}: {differences}')

    case = Path(url).suffix.lstrip('.')
    python_dir = Path(temporary) / f'python-{case}'
    crystal_dir = Path(temporary) / f'crystal-{case}'
    python_dir.mkdir()
    crystal_dir.mkdir()
    download_args = [
        '--ignore-config', '--fixup', 'never', '-o', 'fixture.%(ext)s', url]
    python_download = run(['python', '-m', 'yt_dlp', *download_args], python_dir)
    crystal_download = run([str(binary), *download_args], crystal_dir)
    if python_download.returncode != 0 or crystal_download.returncode != 0:
        raise SystemExit(
            f'download failure for {url}: python={python_download.returncode}, '
            f'crystal={crystal_download.returncode}\n'
            f'python stderr:\n{python_download.stderr}\n'
            f'crystal stderr:\n{crystal_download.stderr}'
        )
    python_files = list(python_dir.glob('fixture.*'))
    crystal_files = list(crystal_dir.glob('fixture.*'))
    if len(python_files) != 1 or len(crystal_files) != 1:
        raise SystemExit(
            f'unexpected outputs for {url}: python={python_files}, crystal={crystal_files}')
    python_bytes = python_files[0].read_bytes()
    crystal_bytes = crystal_files[0].read_bytes()
    if python_bytes != crystal_bytes or crystal_bytes != expected_bytes:
        raise SystemExit(
            f'downloaded byte content differs for {url}: '
            f'python={python_bytes!r}, crystal={crystal_bytes!r}')
    return len(comparable), len(crystal_bytes)


def compare_archive(binary, temporary, url):
    roots = {
        'python': ['python', '-m', 'yt_dlp'],
        'crystal': [str(binary)],
    }
    archives = {}
    for name, command in roots.items():
        directory = Path(temporary) / f'{name}-archive'
        directory.mkdir()
        arguments = [
            '--ignore-config', '--fixup', 'never',
            '--download-archive', 'archive.txt',
            '-o', 'fixture.%(ext)s', url,
        ]
        first = run([*command, *arguments], directory)
        if first.returncode != 0:
            raise SystemExit(
                f'{name} archive first run failed:\n{first.stderr}')
        output = directory / 'fixture.mp4'
        if not output.exists():
            raise SystemExit(f'{name} archive first run did not download output')
        output.unlink()

        second = run([*command, *arguments], directory)
        if second.returncode != 0:
            raise SystemExit(
                f'{name} archive second run failed:\n{second.stderr}')
        if output.exists():
            raise SystemExit(f'{name} archive did not skip the second download')
        archives[name] = (directory / 'archive.txt').read_text(encoding='utf-8')

    if archives['python'] != archives['crystal']:
        raise SystemExit(f'archive mismatch: {archives}')
    return archives['crystal'].strip()


def compare_format_selectors(binary, temporary, url):
    expressions = (
        'best[height<=180]',
        'best[height>180]',
        'best[height<180]/best',
        'best.2',
        'mp4',
    )
    compared = 0
    for expression in expressions:
        arguments = [
            '--ignore-config', '--simulate', '--dump-single-json',
            '-f', expression, url,
        ]
        python = run(['python', '-m', 'yt_dlp', *arguments], temporary)
        crystal = run([str(binary), *arguments], temporary)
        if python.returncode != crystal.returncode:
            raise SystemExit(
                f'format selector exit mismatch for {expression!r}: '
                f'python={python.returncode}, crystal={crystal.returncode}\n'
                f'python stderr:\n{python.stderr}\ncrystal stderr:\n{crystal.stderr}')
        expected = normalized_json(python.stdout)
        actual = normalized_json(crystal.stdout)
        fields = ('height', 'width', 'ext')
        differences = {
            key: (expected.get(key), actual.get(key))
            for key in fields
            if expected.get(key) != actual.get(key)
        }
        if differences:
            raise SystemExit(
                f'format selector mismatch for {expression!r}: {differences}')
        compared += len(fields)
    return len(expressions), compared


def compare_format_sorters(binary, temporary, url):
    expressions = (
        '+res',
        'res:180',
        'res:240',
        'res~300',
        'vcodec:h264',
    )
    compared = 0
    for expression in expressions:
        arguments = [
            '--ignore-config', '--simulate', '--dump-single-json',
            '-f', 'best', '-S', expression, url,
        ]
        python = run(['python', '-m', 'yt_dlp', *arguments], temporary)
        crystal = run([str(binary), *arguments], temporary)
        if python.returncode != crystal.returncode:
            raise SystemExit(
                f'format sort exit mismatch for {expression!r}: '
                f'python={python.returncode}, crystal={crystal.returncode}\n'
                f'python stderr:\n{python.stderr}\ncrystal stderr:\n{crystal.stderr}')
        expected = normalized_json(python.stdout)
        actual = normalized_json(crystal.stdout)
        fields = ('height', 'width', 'vcodec')
        differences = {
            key: (expected.get(key), actual.get(key))
            for key in fields
            if expected.get(key) != actual.get(key)
        }
        if differences:
            raise SystemExit(
                f'format sort mismatch for {expression!r}: {differences}')
        compared += len(fields)
    return len(expressions), compared


def compare_format_availability(binary, temporary, url):
    arguments = [
        '--ignore-config', '--simulate', '--dump-single-json',
        '--check-formats', url,
    ]
    python = run(['python', '-m', 'yt_dlp', *arguments], temporary)
    crystal = run([str(binary), *arguments], temporary)
    if python.returncode != crystal.returncode:
        raise SystemExit(
            f'format availability exit mismatch: '
            f'python={python.returncode}, crystal={crystal.returncode}\n'
            f'python stderr:\n{python.stderr}\ncrystal stderr:\n{crystal.stderr}')
    expected = normalized_json(python.stdout)
    actual = normalized_json(crystal.stdout)
    fields = ('format_id', 'height', 'width')
    differences = {
        key: (expected.get(key), actual.get(key))
        for key in fields
        if expected.get(key) != actual.get(key)
    }
    if differences:
        raise SystemExit(f'format availability mismatch: {differences}')
    return len(fields)


def compare_interactive_format(binary, temporary, url):
    arguments = [
        '--ignore-config', '--simulate', '--dump-single-json',
        '-f', '-', url,
    ]
    python = run(
        ['python', '-m', 'yt_dlp', *arguments], temporary, input_text='100\n')
    crystal = run(
        [str(binary), *arguments], temporary, input_text='100\n')
    if python.returncode != crystal.returncode:
        raise SystemExit(
            f'interactive format exit mismatch: '
            f'python={python.returncode}, crystal={crystal.returncode}\n'
            f'python stderr:\n{python.stderr}\ncrystal stderr:\n{crystal.stderr}')
    expected = normalized_json(python.stdout)
    actual = normalized_json(crystal.stdout)
    fields = ('format_id', 'height', 'width')
    differences = {
        key: (expected.get(key), actual.get(key))
        for key in fields
        if expected.get(key) != actual.get(key)
    }
    if differences:
        raise SystemExit(f'interactive format mismatch: {differences}')
    return len(fields)


def compare_output_templates(binary, temporary, url):
    cases = (
        (['-o', '%(height)06d-%(width)d-%(missing|fallback)s.%(ext)s'], None),
        (['-o', '%(height+20)04d-%(height,width)s.%(ext)s'], None),
        (['-o', '100%%-%(height)s.%(ext)s'], None),
        (['--output-na-placeholder', 'none', '-o', '%(missing)s-%(height)s.%(ext)s'], None),
        (['--trim-filenames', '8', '-o', '%(height)s-long-name.%(ext)s'], None),
        (['-o', '%(formats.0.height)04d-%(formats.-1.width)d.%(ext)s'], None),
    )
    for arguments, _ in cases:
        common = [
            '--ignore-config', '--simulate', '--get-filename',
            *arguments, url,
        ]
        python = run(['python', '-m', 'yt_dlp', *common], temporary)
        crystal = run([str(binary), *common], temporary)
        if python.returncode != crystal.returncode:
            raise SystemExit(
                f'output template exit mismatch for {arguments!r}: '
                f'python={python.returncode}, crystal={crystal.returncode}\n'
                f'python stderr:\n{python.stderr}\ncrystal stderr:\n{crystal.stderr}')
        expected = python.stdout.strip()
        actual = crystal.stdout.strip()
        if expected != actual:
            raise SystemExit(
                f'output template mismatch for {arguments!r}: '
                f'python={expected!r}, crystal={actual!r}')
    return len(cases)


def compare_print_templates(binary, temporary, url):
    cases = (
        ['-O', 'height'],
        ['-O', '%(height)04d-%(missing|fallback)s'],
        ['-O', 'height', '-O', 'width'],
    )
    for arguments in cases:
        common = ['--ignore-config', *arguments, url]
        python = run(['python', '-m', 'yt_dlp', *common], temporary)
        crystal = run([str(binary), *common], temporary)
        if python.returncode != crystal.returncode:
            raise SystemExit(
                f'print template exit mismatch for {arguments!r}: '
                f'python={python.returncode}, crystal={crystal.returncode}\n'
                f'python stderr:\n{python.stderr}\ncrystal stderr:\n{crystal.stderr}')
        if python.stdout.strip() != crystal.stdout.strip():
            raise SystemExit(
                f'print template mismatch for {arguments!r}: '
                f'python={python.stdout.strip()!r}, crystal={crystal.stdout.strip()!r}')
    return len(cases)


def compare_metadata_parser(binary, temporary, url):
    cases = (
        (
            ['--parse-metadata', 'title:%(parsed_title)s'],
            ('title', 'parsed_title'),
        ),
        (
            ['--parse-metadata', 'after_filter:title:%(parsed_title)s'],
            ('title', 'parsed_title'),
        ),
        (
            ['--replace-in-metadata', 'title', 'fixture', 'changed'],
            ('title',),
        ),
        (
            [
                '--parse-metadata', 'title:%(artist)s',
                '--replace-in-metadata', 'artist', 'fixture', 'performer',
            ],
            ('title', 'artist'),
        ),
    )
    compared = 0
    for arguments, fields in cases:
        common = [
            '--ignore-config', '--simulate', '--dump-single-json',
            *arguments, url,
        ]
        python = run(['python', '-m', 'yt_dlp', *common], temporary)
        crystal = run([str(binary), *common], temporary)
        if python.returncode != crystal.returncode:
            raise SystemExit(
                f'metadata parser exit mismatch for {arguments!r}: '
                f'python={python.returncode}, crystal={crystal.returncode}\n'
                f'python stderr:\n{python.stderr}\ncrystal stderr:\n{crystal.stderr}')
        expected = normalized_json(python.stdout)
        actual = normalized_json(crystal.stdout)
        differences = {
            key: (expected.get(key), actual.get(key))
            for key in fields
            if expected.get(key) != actual.get(key)
        }
        if differences:
            raise SystemExit(
                f'metadata parser mismatch for {arguments!r}: {differences}')
        compared += len(fields)
    return len(cases), compared


def compare_cookie_file(binary, temporary, url):
    for name, command in (
        ('python', ['python', '-m', 'yt_dlp']),
        ('crystal', [str(binary)]),
    ):
        directory = Path(temporary) / f'{name}-cookies'
        directory.mkdir()
        cookie_file = directory / 'cookies.txt'
        cookie_file.write_text(
            '# Netscape HTTP Cookie File\n'
            '127.0.0.1\tFALSE\t/\tFALSE\t0\tsession\tfixture\n',
            encoding='utf-8',
        )
        arguments = [
            '--ignore-config', '--fixup', 'never',
            '--cookies', str(cookie_file),
            '-o', 'fixture.%(ext)s', url,
        ]
        result = run([*command, *arguments], directory)
        if result.returncode != 0:
            raise SystemExit(
                f'{name} cookie-file download failed:\n{result.stderr}')
        output = directory / 'fixture.mp4'
        if output.read_bytes() != FixtureHandler.cookie_payload:
            raise SystemExit(f'{name} cookie-file download bytes differ')
    return len(FixtureHandler.cookie_payload)


def compare_http_proxy(binary, temporary, proxy_url):
    url = 'http://media.example.invalid/proxy.mp4'
    for name, command in (
        ('python', ['python', '-m', 'yt_dlp']),
        ('crystal', [str(binary)]),
    ):
        directory = Path(temporary) / f'{name}-proxy'
        directory.mkdir()
        arguments = [
            '--ignore-config', '--fixup', 'never',
            '--proxy', proxy_url,
            '-o', 'fixture.%(ext)s', url,
        ]
        result = run([*command, *arguments], directory)
        if result.returncode != 0:
            raise SystemExit(
                f'{name} HTTP proxy download failed:\n{result.stderr}')
        output = directory / 'fixture.mp4'
        if output.read_bytes() != ProxyHandler.payload:
            raise SystemExit(f'{name} HTTP proxy download bytes differ')
    return len(ProxyHandler.payload)


def compare_socks_proxy(binary, temporary, proxy_url):
    url = 'http://media.example.invalid/socks.mp4'
    for name, command in (
        ('python', ['python', '-m', 'yt_dlp']),
        ('crystal', [str(binary)]),
    ):
        directory = Path(temporary) / f'{name}-socks'
        directory.mkdir()
        arguments = [
            '--ignore-config', '--fixup', 'never',
            '--proxy', proxy_url,
            '-o', 'fixture.%(ext)s', url,
        ]
        result = run([*command, *arguments], directory)
        if result.returncode != 0:
            raise SystemExit(
                f'{name} SOCKS proxy download failed:\n{result.stderr}')
        output = directory / 'fixture.mp4'
        if output.read_bytes() != Socks5Handler.payload:
            raise SystemExit(f'{name} SOCKS proxy download bytes differ')
    return len(Socks5Handler.payload)


def compare_subtitles(binary, temporary, url):
    expected = FixtureHandler.routes['/captions.vtt'][1]
    for name, command in (
        ('python', ['python', '-m', 'yt_dlp']),
        ('crystal', [str(binary)]),
    ):
        directory = Path(temporary) / f'{name}-subtitles'
        directory.mkdir()
        arguments = [
            '--ignore-config', '--skip-download',
            '--write-subs', '--sub-langs', 'en', '--sub-format', 'vtt',
            '-o', 'fixture.%(ext)s', url,
        ]
        result = run([*command, *arguments], directory)
        if result.returncode != 0:
            raise SystemExit(
                f'{name} subtitle download failed:\n{result.stderr}')
        subtitle = directory / 'fixture.en.vtt'
        if not subtitle.exists() or subtitle.read_bytes() != expected:
            raise SystemExit(
                f'{name} subtitle output differs: '
                f'{subtitle.read_bytes() if subtitle.exists() else None!r}')
        if any(directory.glob('fixture.mp4')):
            raise SystemExit(f'{name} --skip-download wrote a media file')
    return len(expected)


def main():
    parser = argparse.ArgumentParser()
    binary_name = 'cr-dlp.exe' if os.name == 'nt' else 'cr-dlp'
    parser.add_argument('--crystal-binary', type=Path, default=ROOT / 'bin' / binary_name)
    args = parser.parse_args()

    server = ThreadingHTTPServer(('127.0.0.1', 0), FixtureHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base_url = f'http://127.0.0.1:{server.server_port}'
    proxy = ThreadingHTTPServer(('127.0.0.1', 0), ProxyHandler)
    proxy_thread = threading.Thread(target=proxy.serve_forever, daemon=True)
    proxy_thread.start()
    proxy_url = f'http://127.0.0.1:{proxy.server_port}'
    socks = socketserver.ThreadingTCPServer(('127.0.0.1', 0), Socks5Handler)
    socks_thread = threading.Thread(target=socks.serve_forever, daemon=True)
    socks_thread.start()
    socks_url = f'socks5h://127.0.0.1:{socks.server_address[1]}'

    try:
        with tempfile.TemporaryDirectory() as temporary:
            cases = (
                ('fixture.mp4', FixtureHandler.direct_payload),
                ('fixture.m3u8', b'HLS-AHLS-B'),
                ('fixture.mpd', b'DASH-IDASH-ADASH-B'),
            )
            fields = 0
            byte_count = 0
            for path, expected_bytes in cases:
                compared, downloaded = compare_case(
                    args.crystal_binary, temporary, f'{base_url}/{path}', expected_bytes)
                fields += compared
                byte_count += downloaded
            archive_id = compare_archive(
                args.crystal_binary, temporary, f'{base_url}/fixture.mp4')
            selector_cases, selector_fields = compare_format_selectors(
                args.crystal_binary, temporary, f'{base_url}/master.m3u8')
            sort_cases, sort_fields = compare_format_sorters(
                args.crystal_binary, temporary, f'{base_url}/master.m3u8')
            availability_fields = compare_format_availability(
                args.crystal_binary, temporary, f'{base_url}/probe-master.m3u8')
            interactive_fields = compare_interactive_format(
                args.crystal_binary, temporary, f'{base_url}/master.m3u8')
            template_cases = compare_output_templates(
                args.crystal_binary, temporary, f'{base_url}/master.m3u8')
            print_cases = compare_print_templates(
                args.crystal_binary, temporary, f'{base_url}/master.m3u8')
            metadata_cases, metadata_fields = compare_metadata_parser(
                args.crystal_binary, temporary, f'{base_url}/fixture.mp4')
            cookie_bytes = compare_cookie_file(
                args.crystal_binary, temporary, f'{base_url}/cookie.mp4')
            proxy_bytes = compare_http_proxy(
                args.crystal_binary, temporary, proxy_url)
            socks_bytes = compare_socks_proxy(
                args.crystal_binary, temporary, socks_url)
            subtitle_bytes = compare_subtitles(
                args.crystal_binary, temporary, f'{base_url}/master.m3u8')
            print(
                f'PASS: {len(cases)} cases, {fields} normalized fields, exit statuses, '
                f'{byte_count} downloaded bytes, archive ID {archive_id!r}, and '
                f'{selector_cases} format selectors ({selector_fields} fields) plus '
                f'{sort_cases} format sorts ({sort_fields} fields) plus '
                f'format availability ({availability_fields} fields), '
                f'interactive selection ({interactive_fields} fields), '
                f'{template_cases} output templates, {print_cases} print templates, '
                f'{metadata_cases} metadata parser cases ({metadata_fields} fields), '
                f'{cookie_bytes} authenticated cookie bytes, and '
                f'{proxy_bytes} HTTP-proxied bytes plus '
                f'{socks_bytes} SOCKS-proxied bytes plus '
                f'{subtitle_bytes} subtitle bytes match'
            )
    finally:
        server.shutdown()
        server.server_close()
        proxy.shutdown()
        proxy.server_close()
        socks.shutdown()
        socks.server_close()


if __name__ == '__main__':
    main()
