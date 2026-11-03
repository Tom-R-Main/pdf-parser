#!/usr/bin/env python3
"""Explicit, offline external-OCR replay through the public CLI and strict evaluator.

No raster pixels are processed: the fixture provider emits PNG dimension headers
and recorded TSV. Live OCR semantic qualification is a separate command/lane.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import struct
import subprocess
import sys
import time

from owned_process import cleanup_process_group

ROOT = Path(__file__).resolve().parents[2]


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def words(tsv: bytes) -> list[list[str]]:
    # Tesseract TSV text contains literal quotes; CSV quote parsing loses words.
    return [fields for line in tsv.decode().splitlines()
            if len(fields := line.split('\t')) == 12 and fields[0] == '5' and fields[11].strip()]


def load_fixture(path: Path) -> dict:
    fixture = json.loads(path.read_text())
    tsv = (path.parent / fixture['tsv']).resolve()
    if sha(tsv) != fixture['tsv_sha256']:
        raise ValueError('recorded TSV hash mismatch')
    if sha(ROOT / fixture['pdf']) != fixture['pdf_sha256']:
        raise ValueError('input PDF hash mismatch')
    if fixture['page_index'] != 0 or not fixture['grayscale'] or fixture['language'] != 'eng':
        raise ValueError('provider currently supports one grayscale English first-page capture')
    if fixture.get('capture'):
        capture_path = path.parent / fixture['capture']
        if sha(capture_path) != fixture['capture_sha256']:
            raise ValueError('capture provenance hash mismatch')
        capture = json.loads(capture_path.read_text())
        if (capture['tsv_sha256'], capture['input_pdf_sha256'], capture['dpi'], capture['psm'],
            [capture['pixel_width'], capture['pixel_height']]) != (
                fixture['tsv_sha256'], fixture['pdf_sha256'], fixture['dpi'], fixture['psm'], fixture['pixels']):
            raise ValueError('capture provenance does not match replay input/configuration')
    fixture['tsv_path'] = str(tsv)
    return fixture


def provider(role: str, args: list[str]) -> int:
    fixture = load_fixture(Path(os.environ['RECORDED_OCR_FIXTURE']))
    reference = Path(fixture['tsv_path']).read_bytes()
    event = {'mode': 'recorded_external_ocr', 'role': role, 'argv': args}
    if role == 'raster':
        dpi = int(args[args.index('-r') + 1])
        width, height = (int(args[args.index(flag) + 1]) for flag in ('-W', '-H'))
        if sha(Path(args[-2])) != fixture['pdf_sha256']:
            raise ValueError('raster request PDF mismatch')
        if '-gray' not in args or any(args[args.index(flag) + 1] != value
                for flag, value in (('-f', '1'), ('-l', '1'), ('-x', '0'), ('-y', '0'))):
            raise ValueError('recorded raster requires the full grayscale first page')
        if dpi == fixture['dpi'] and [width, height] != fixture['pixels']:
            raise ValueError('recorded raster geometry mismatch')
        Path(args[-1] + '.png').write_bytes(b'\x89PNG\r\n\x1a\n' + struct.pack('>I', 13) + b'IHDR' + struct.pack('>II', width, height))
        event.update(dpi=dpi, pixels=[width, height], dimension_header_only=True)
    else:
        dpi, psm = (int(args[args.index(flag) + 1]) for flag in ('--dpi', '--psm'))
        image = Path(args[0]).read_bytes()
        pixels = list(struct.unpack('>II', image[16:24]))
        recorded = (dpi, psm) == (fixture['dpi'], fixture['psm'])
        if args[args.index('-l') + 1] != fixture['language']:
            raise ValueError('OCR language mismatch')
        # Explicit empty primary control lets the evaluator's existing default
        # bounded fallback consume the capture at its actual 300 dpi / PSM 11.
        if not recorded and (dpi, psm) != (200, 6):
            raise ValueError('unrecorded OCR configuration')
        if recorded and pixels != fixture['pixels']:
            raise ValueError('OCR request geometry mismatch')
        event.update(dpi=dpi, psm=psm, pixels=pixels,
                     input='recorded_tsv' if recorded else 'synthetic_empty_primary',
                     tsv_sha256=fixture['tsv_sha256'] if recorded else None)
        sys.stdout.buffer.write(reference if recorded else reference.splitlines(keepends=True)[0])
    with Path(os.environ['RECORDED_OCR_EVENTS']).open('a') as stream:
        stream.write(json.dumps(event) + '\n')
    return 0


def run(command: list[str], output: Path, label: str, env: dict, *, timeout=90) -> dict:
    start = time.monotonic()
    timed_out = False
    with (output / (label + '.stdout')).open('xb') as stdout, (output / (label + '.stderr')).open('xb') as stderr:
        child = subprocess.Popen(command, cwd=ROOT, env=env, stdout=stdout, stderr=stderr, start_new_session=True)
        try:
            child.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
        finally:
            cleanup = cleanup_process_group(child)
    return dict(command=command, pid=child.pid, exit_code=child.returncode, timed_out=timed_out, duration_seconds=round(time.monotonic() - start, 3),
                stdout=str(output / (label + '.stdout')), stderr=str(output / (label + '.stderr')),
                stdout_sha256=sha(output / (label + '.stdout')), stderr_sha256=sha(output / (label + '.stderr')),
                owned_process_group_cleaned=True, process_group_cleanup=cleanup)


def verify(args: argparse.Namespace) -> dict:
    fixture_path = args.fixture.resolve()
    fixture = load_fixture(fixture_path)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    report = dict(mode='controlled_downstream_routing_replay', status='fail', fixture_sha256=sha(fixture_path),
                  fixture=fixture, commands=[], live_ocr_qualified=False,
                  raster='dimension headers only; capture PNG is provenance, not a replay input',
                  eval_primary='synthetic empty TSV; default bounded fallback consumes recorded TSV')
    try:
        metadata = next(json.loads(line) for line in args.metadata.read_text().splitlines()
                        if json.loads(line)['doc_id'] == fixture['doc_id'])
        expected = {key: metadata['expected_' + key] for key in ('ocr_pages', 'table_regions', 'formula_regions')}
        if any(value is None for value in expected.values()):
            raise ValueError('recorded gate requires all original route expectations')
        rows = [line for line in args.manifest.read_text().splitlines()
                if not line.startswith('#') and line.split('\t')[1:2] == [fixture['doc_id']]]
        if len(rows) != 1 or rows[0].split('\t')[2] != fixture['pdf']:
            raise ValueError('fixture must identify exactly one original manifest row')
        manifest = output / 'original-row.tsv'
        manifest.write_text(rows[0] + '\n')
        report.update(metadata_sha256=sha(args.metadata), original_metadata=metadata, expected=expected)
        env = os.environ | {'RECORDED_OCR_FIXTURE': str(fixture_path), 'RECORDED_OCR_EVENTS': str(output / 'provider-events.jsonl')}
        executables = []
        for role in ('ocr', 'raster'):
            executable = output / ('recorded-' + role)
            executable.write_text('#!/bin/sh\nexec ' + shlex.join([sys.executable, str(Path(__file__).resolve()), '--provider-' + role]) + ' "$@"\n')
            executable.chmod(0o700)
            executables.append(str(executable))
        common = ['--ocr-executable', executables[0], '--ocr-rasterizer', executables[1]]
        parser, evaluator = str(args.parser.resolve()), str(args.evaluator.resolve())
        report['binary_sha256'] = {'parser': sha(Path(parser)), 'evaluator': sha(Path(evaluator))}
        command = [parser, 'extract-adaptive', '--input', fixture['pdf'], '--source-id', fixture['doc_id'], '--format', 'artifact-jsonl',
                   '--ocr-policy', 'single', '--ocr-dpi', str(fixture['dpi']), '--ocr-psm', str(fixture['psm']), *common]
        report['commands'].append(run(command, output, 'recorded-cli', env))
        command = [evaluator, '--adaptive', *common, '--manifest', str(manifest), '--metadata', str(args.metadata.resolve())]
        report['commands'].append(run(command, output, 'recorded-strict-eval', env))
        if any(result['exit_code'] != 0 for result in report['commands']):
            raise ValueError('recorded parser/evaluator failed; strict mismatch remains a failure')
        results = [json.loads(line) for line in (output / 'recorded-strict-eval.stdout').read_text().splitlines()]
        if len(results) != 1 or results[0]['doc_id'] != fixture['doc_id']:
            raise ValueError('missing evaluator document identity')
        actual = {key: results[0][key] for key in expected}
        report['actual'] = actual
        if actual != expected:
            raise ValueError('recorded route counts differ from original metadata')
        artifacts = [json.loads(line) for line in (output / 'recorded-cli.stdout').read_text().splitlines()]
        selected = [r for r in artifacts if r.get('record_type') == 'specialist_attempt' and r.get('selected')]
        if len(selected) != 1 or selected[0]['quality']['span_count'] != len(words(Path(fixture['tsv_path']).read_bytes())):
            raise ValueError('CLI did not consume the recorded OCR words')
        config = selected[0]['config']
        if (config['dpi'], config['psm'], config['language'], config['grayscale']) != (
                fixture['dpi'], fixture['psm'], fixture['language'], fixture['grayscale']):
            raise ValueError('selected attempt does not match recorded configuration')
        geometry = selected[0]['raster_transform']
        if [geometry['pixel_width'], geometry['pixel_height']] != fixture['pixels']:
            raise ValueError('selected attempt does not match recorded geometry')
        events = [json.loads(line) for line in (output / 'provider-events.jsonl').read_text().splitlines()]
        if [event['input'] for event in events if event['role'] == 'ocr'] != [
                'recorded_tsv', 'synthetic_empty_primary', 'recorded_tsv']:
            raise ValueError('unexpected replay provider selection history')
        report.update(selected_attempt=selected[0], route_counts=artifacts[0]['route_counts'], provider_events=events)
        if any(artifacts[0]['route_counts'][key] != expected[key] for key in ('table_regions', 'formula_regions')):
            raise ValueError('CLI route counts differ from original metadata')
        # Change the recognized input, not any expected count or parser option.
        lines = Path(fixture['tsv_path']).read_bytes().splitlines(keepends=True)
        negative = output / 'changed.tsv'
        negative.write_bytes(b''.join(line for line in lines if not line.startswith(b'5\t')) +
                             next(line for line in lines if line.startswith(b'5\t')))
        changed = fixture | {'tsv': str(negative), 'tsv_sha256': sha(negative), 'capture': None,
                             'qualification': 'Generated changed-input negative control; not the captured TSV'}
        changed.pop('tsv_path')
        negative_fixture = output / 'changed-fixture.json'
        negative_fixture.write_text(json.dumps(changed, indent=2) + '\n')
        result = run(command, output, 'changed-tsv-strict-eval', env | {'RECORDED_OCR_FIXTURE': str(negative_fixture)})
        report['commands'].append(result)
        diagnostic = [json.loads(line) for line in (output / 'changed-tsv-strict-eval.stderr').read_text().splitlines()
                      if line.startswith('{"diagnostic":"route_count_mismatch"')]
        if result['timed_out'] or result['exit_code'] == 0 or len(diagnostic) != 1 or diagnostic[0]['expected'] != expected or diagnostic[0]['doc_id'] != fixture['doc_id']:
            raise ValueError('changed TSV did not fail the original strict route assertion')
        report.update(negative_control=diagnostic[0], changed_tsv_sha256=sha(negative))
        # A corrupt capture must be rejected before starting any parser command.
        corrupt = fixture | {'tsv': str(negative)}
        corrupt.pop('tsv_path')
        corrupt_fixture = output / 'corrupt-fixture.json'
        corrupt_fixture.write_text(json.dumps(corrupt) + '\n')
        try:
            load_fixture(corrupt_fixture)
        except ValueError as error:
            if str(error) != 'recorded TSV hash mismatch':
                raise
            report['corrupt_tsv_rejected'] = str(error)
        else:
            raise ValueError('corrupt TSV was admitted')
        report['status'] = 'pass'
    except Exception as error:
        report['status'] = 'fail'
        report['error'] = str(error)
    finally:
        (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    return report


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] in ('--provider-ocr', '--provider-raster'):
        return provider(sys.argv[1].removeprefix('--provider-'), sys.argv[2:])
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fixture', type=Path, required=True)
    parser.add_argument('--parser', type=Path, default=Path('zig-out/bin/pdf-parser'))
    parser.add_argument('--evaluator', type=Path, default=Path('zig-out/bin/pdf-parser-eval'))
    parser.add_argument('--manifest', type=Path, default=ROOT / 'benchmark/eval/corpus/manifest.tsv')
    parser.add_argument('--metadata', type=Path, default=ROOT / 'benchmark/eval/corpus/metadata.jsonl')
    parser.add_argument('--output', type=Path, required=True)
    try:
        report = verify(parser.parse_args())
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f'Recorded external-OCR replay failed: {error}\n')
    print(json.dumps(report, indent=2))
    return 0 if report['status'] == 'pass' else 1


if __name__ == '__main__':
    raise SystemExit(main())
