#!/usr/bin/env python3
"""Bounded, repeatable local M1 acceptance; GUI-only checks remain explicit."""
import json
import pathlib
import subprocess
import sys
import time

root = pathlib.Path(__file__).resolve().parents[1]
output = root / 'build' / 'acceptance'
output.mkdir(parents=True, exist_ok=True)
result = output / ('M1-' + time.strftime('%Y%m%d-%H%M%S') + '.xcresult')
command = ['xcodebuild', '-quiet', '-project', 'MacPDF.xcodeproj', '-scheme', 'MacPDF',
           '-destination', 'platform=macOS,arch=arm64', '-derivedDataPath', str(output / 'DerivedData'),
           '-resultBundlePath', str(result), 'CODE_SIGN_IDENTITY=-', 'DEVELOPMENT_TEAM=', 'test']
with (output / 'latest.log').open('w') as log:
    try:
        run = subprocess.run(command, cwd=root, stdout=log, stderr=subprocess.STDOUT, timeout=240)
    except subprocess.TimeoutExpired:
        print('Acceptance timed out after 240 seconds; inspect build/acceptance/latest.log')
        sys.exit(2)
if run.returncode:
    print('Acceptance failed; inspect build/acceptance/latest.log')
    sys.exit(run.returncode)
summary = subprocess.run(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(result), '--format', 'json'],
                         capture_output=True, text=True, timeout=30, check=True)
data = json.loads(summary.stdout)
(output / 'latest.json').write_text(json.dumps(data, indent=2))
print(f"{data['result']}: {data['passedTests']} passed, {data['failedTests']} failed, {data['skippedTests']} skipped")
print('Evidence: ' + str(result))
print('GUI-only remaining: Finder drag gesture; current app visual smoke check.')
