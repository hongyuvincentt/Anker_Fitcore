#!/usr/bin/env python3
"""Export separate public task deliveries, without scanning private source trees."""
from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile

ROOT = Path(__file__).resolve().parents[1]
LHY_FILES = (
    'Package.swift',
    'ios/Fitcore.xcodeproj/project.pbxproj',
    'ios/Fitcore.xcodeproj/project.xcworkspace/contents.xcworkspacedata',
    'ios/Fitcore.xcodeproj/xcshareddata/xcschemes/Fitcore-Mock.xcscheme',
    'ios/Configuration/Base.xcconfig', 'ios/Configuration/Debug.xcconfig',
    'ios/Configuration/Release.xcconfig', 'ios/Configuration/Local.xcconfig.example',
    'ios/Fitcore/App/FitcoreApp.swift', 'ios/Fitcore/Resources/Info.plist',
    'scripts/generate_xcode_project.py', 'scripts/verify.py',
    'scripts/check_core.swift', 'scripts/check_dynamic_records.swift',
    'docs/LHY-01-LOCAL-HANDOFF.md', 'docs/LHY-01-VERIFICATION.json',
)
D01_FILES = (
    'data/D01/README.md', 'data/D01/SAMPLING_MATRIX.md',
    'data/D01/scripts/d01.py', 'data/D01/tests/test_d01.py',
    'data/D01/templates/CONSENT_REGISTER.csv', 'data/D01/templates/WAV_MANIFEST.csv',
    'data/D01/verification/RED_GREEN.md',
)
# No repository-wide glob or traversal through unrecognized source groups.
SOURCE_DIRECTORIES = {
    'ios/Fitcore/App', 'ios/Fitcore/DesignSystem', 'ios/Fitcore/Core',
    'ios/Fitcore/Core/Configuration', 'ios/Fitcore/Core/Networking',
    'ios/Fitcore/Core/Models', 'ios/Fitcore/Core/Audio', 'ios/Fitcore/Core/Persistence',
    'ios/Fitcore/Resources', 'ios/Fitcore/Resources/Assets.xcassets',
    'ios/Fitcore/Features', 'ios/Fitcore/Services',
    'ios/Fitcore/Services/Training', 'ios/Fitcore/Services/Recorder',
    'ios/Fitcore/Services/Audio',
    *('ios/Fitcore/Features/' + group for group in (
        'Settings', 'Today', 'Training', 'Profile', 'Review', 'History', 'Device', 'Capture')),
}
ASSETS = 'ios/Fitcore/Resources/Assets.xcassets'


def public_file(root, name):
    path = root
    for part in Path(name).parts:
        path = path / part
        if path.is_symlink():
            return False
    return path.is_file()


def source_tree(root, relative, suffixes):
    directory = root / relative
    ancestor = root
    for part in Path(relative).parts:
        ancestor = ancestor / part
        if ancestor.is_symlink():
            return []
    if not directory.is_dir():
        return []
    selected = []
    for child in sorted(directory.iterdir()):
        name = child.relative_to(root).as_posix()
        if (child.is_symlink() or child.name.startswith('.')
                or any(ord(char) < 32 or char == '\\' for char in child.name)
                or child.stem.lower() in {'credentials', 'secrets', 'token', 'tokens'}):
            continue
        if child.is_dir():
            is_asset = (relative == ASSETS
                        and child.suffix in {'.imageset', '.colorset', '.appiconset'})
            if name not in SOURCE_DIRECTORIES and not is_asset:
                continue
            selected.extend(source_tree(root, name, suffixes))
        elif child.suffix.lower() in suffixes:
            is_source = child.suffix == '.swift'
            is_asset = (name.startswith(ASSETS + '/')
                        and (child.suffix == '.png' or child.name == 'Contents.json'))
            if is_source or is_asset or name == 'ios/Fitcore/Resources/Info.plist':
                selected.append(name)
    return selected


def task_payload(root, task, evidence):
    required = LHY_FILES if task == 'LHY-01' else D01_FILES
    missing = [name for name in required if not public_file(root, name)]
    if missing:
        raise ValueError(f'{task}: missing required public files: {", ".join(missing)}')
    names = set(required)
    if task == 'LHY-01':
        names.update(source_tree(root, 'ios/Fitcore', {'.swift', '.png', '.json', '.plist'}))
        tests = source_tree(root, 'tests/WAVCaptureKitTests', {'.swift'})
        names.update(tests)
        for group in ('ios/Fitcore/Core/Audio/', 'ios/Fitcore/Services/Audio/',
                      'ios/Fitcore/Features/Capture/', 'tests/WAVCaptureKitTests/'):
            if not any(name.startswith(group) and name.endswith('.swift') for name in names):
                raise ValueError(f'{task}: missing Swift sources in {group}')
    payload = {name: (root / name).read_bytes() for name in sorted(names)}
    for name, content in payload.items():
        if name.endswith('.csv'):
            rows = list(csv.reader(io.StringIO(content.decode('utf-8-sig'))))
            if len(rows) != 1 or not rows[0] or not all(rows[0]):
                raise ValueError(f'{task}: CSV templates must contain only a nonempty header: {name}')
    refs = []
    for reference in evidence:
        if reference not in payload:
            raise ValueError(f'{task}: evidence must name a packaged public file: {reference}')
        refs.append(reference)
    readme = 'docs/LHY-01-LOCAL-HANDOFF.md' if task == 'LHY-01' else 'data/D01/README.md'
    payload['README.md'] = payload[readme]
    delivery = {
        'task': task,
        'software_validation': {
            'status': 'evidence_supplied' if refs else 'not_verified',
            'evidence': refs,
            'note': 'Evidence references are supplied by the operator; packaging does not execute checks.',
        },
        'human_acceptance': 'pending_acceptance',
        'device_validation': 'not_verified',
        'real_person_data_included': False,
    }
    payload['DELIVERY.json'] = (json.dumps(delivery, indent=2, ensure_ascii=False) + '\n').encode()
    payload['SHA256SUMS'] = ''.join(
        f'{hashlib.sha256(content).hexdigest()}  {name}\n'
        for name, content in sorted(payload.items())
    ).encode()
    return payload


def package_tasks(root, output_dir, task, software_evidence=()):
    root, output_dir = Path(root), Path(output_dir)
    if task not in {'LHY-01', 'D01', 'all'}:
        raise ValueError(f'Unsupported task: {task}')
    tasks = ['LHY-01', 'D01'] if task == 'all' else [task]
    # Preflight every task and target before creating any delivery.
    outputs = [output_dir / f'{name}-delivery.zip' for name in tasks]
    for output in outputs:
        if output.exists() or output.is_symlink():
            raise FileExistsError(f'Refusing to overwrite {output}; choose a fresh output directory')
    payloads = []
    for name in tasks:
        # all accepts task-specific references; single-task mode rejects foreign paths.
        evidence = software_evidence
        if task == 'all':
            prefix = 'docs/LHY-01-' if name == 'LHY-01' else 'data/D01/'
            evidence = [item for item in software_evidence if item.startswith(prefix)]
        payloads.append(task_payload(root, name, evidence))
    if task == 'all':
        known = set().union(*(set(payload) for payload in payloads))
        if any(item not in known for item in software_evidence):
            raise ValueError('Evidence must reference a packaged public file')
    output_dir.mkdir(parents=True, exist_ok=True)
    for output, payload in zip(outputs, payloads):
        with ZipFile(output, 'x', compression=ZIP_DEFLATED) as archive:
            for name, content in sorted(payload.items()):
                archive.writestr(name, content)
    return outputs


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--task', choices=('LHY-01', 'D01', 'all'), required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--software-evidence', action='append', default=[],
                        help='Relative public file included in the delivery; repeat as needed')
    args = parser.parse_args()
    try:
        for path in package_tasks(ROOT, args.output_dir, args.task, args.software_evidence):
            print(path)
    except (ValueError, FileExistsError) as error:
        parser.exit(1, f'{error}\n')


if __name__ == '__main__':
    main()
