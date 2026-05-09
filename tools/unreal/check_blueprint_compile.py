"""
UE5 Blueprint Compilation Status Checker
=========================================
Detects whether Blueprint .uasset files have compilation errors
by parsing the binary header, name table, and searching for
error-related property serialization and text strings.

Heuristics used:
  1. bHasCompilerMessage in name table -> node-level compile errors exist
     (this property's default is false; it only appears in the name table
      when serialized, meaning at least one node has bHasCompilerMessage=true)
  2. ErrorMsg / ErrorType in name table -> error detail properties present
  3. UTF-16LE error text strings in binary -> actual error messages

Usage:
  python check_blueprint_compile.py <path_to_uasset>
  python check_blueprint_compile.py --scan <content_directory> [--output report.md]
"""

import struct
import sys
import os
import time
import argparse
from pathlib import Path

sys.stdout.reconfigure(encoding='utf-8', errors='replace')

# ---------------------------------------------------------------------------
# UE5 header / name-table parser
# ---------------------------------------------------------------------------

def _read_fstring(data, pos):
    if pos + 4 > len(data):
        return '', pos
    slen = struct.unpack_from('<i', data, pos)[0]
    pos += 4
    if slen == 0:
        return '', pos
    if slen > 0 and slen < 65536:
        end = pos + slen
        if end > len(data):
            return '', end
        s = data[pos:end - 1].decode('utf-8', errors='replace')
        return s, end
    if slen < 0 and slen > -65536:
        actual = -slen
        end = pos + actual * 2
        if end > len(data):
            return '', end
        s = data[pos:end - 2].decode('utf-16-le', errors='replace')
        return s, end
    return '', pos


def parse_uasset_header(data):
    if len(data) < 30:
        return None
    tag = struct.unpack_from('<I', data, 0)[0]
    if tag != 0x9E2A83C1:
        return None

    lfv = struct.unpack_from('<i', data, 4)[0]
    pos = 8

    if lfv != -4:
        pos += 4                     # LegacyUE3Version

    ue4_ver = struct.unpack_from('<i', data, pos)[0]; pos += 4

    ue5_ver = 0
    if lfv <= -8:
        ue5_ver = struct.unpack_from('<i', data, pos)[0]; pos += 4

    pos += 4                         # FileVersionLicenseeUE4

    if lfv <= -2:
        cc = struct.unpack_from('<i', data, pos)[0]; pos += 4
        if 0 < cc < 1000:
            pos += cc * 20           # GUID(16) + Version(4) each

    total_hdr = struct.unpack_from('<i', data, pos)[0]; pos += 4
    _, pos = _read_fstring(data, pos)  # FolderName
    pkg_flags = struct.unpack_from('<I', data, pos)[0]; pos += 4

    name_count  = struct.unpack_from('<i', data, pos)[0]
    name_offset = struct.unpack_from('<i', data, pos + 4)[0]; pos += 8

    # SoftObjectPaths
    pos += 8

    # LocalizationId
    _, pos = _read_fstring(data, pos)

    # GatherableTextData
    pos += 8

    export_count  = struct.unpack_from('<i', data, pos)[0]
    export_offset = struct.unpack_from('<i', data, pos + 4)[0]; pos += 8
    import_count  = struct.unpack_from('<i', data, pos)[0]
    import_offset = struct.unpack_from('<i', data, pos + 4)[0]; pos += 8

    return {
        'ue4_ver': ue4_ver, 'ue5_ver': ue5_ver, 'lfv': lfv,
        'pkg_flags': pkg_flags, 'total_hdr': total_hdr,
        'name_count': name_count, 'name_offset': name_offset,
        'export_count': export_count, 'export_offset': export_offset,
        'import_count': import_count, 'import_offset': import_offset,
    }


def parse_names(data, offset, count):
    names = []
    pos = offset
    for _ in range(count):
        if pos + 4 > len(data):
            break
        slen = struct.unpack_from('<i', data, pos)[0]; pos += 4
        if slen == 0:
            names.append(''); pos += 4; continue
        if 0 < slen < 8192:
            end = pos + slen
            if end > len(data):
                break
            names.append(data[pos:end - 1].decode('utf-8', errors='replace'))
            pos = end
        elif -8192 < slen < 0:
            actual = -slen
            end = pos + actual * 2
            if end > len(data):
                break
            names.append(data[pos:end - 2].decode('utf-16-le', errors='replace'))
            pos = end
        else:
            break
        pos += 4                     # hash
    return names

# ---------------------------------------------------------------------------
# Blueprint detection & compilation check
# ---------------------------------------------------------------------------

BLUEPRINT_CLASS_NAMES = {
    'Blueprint', 'WidgetBlueprint', 'AnimBlueprint',
    'LevelSequenceDirectorBlueprint', 'BehaviorTree',
    'GameplayAbilityBlueprint', 'EditorUtilityBlueprint',
    'ControlRigBlueprint',
}

BLUEPRINT_INDICATORS = {
    'BlueprintSystemVersion', 'BlueprintGeneratedClass',
    'UbergraphPages', 'GeneratedClass',
}


def is_blueprint(names_set):
    if names_set & BLUEPRINT_CLASS_NAMES:
        return True
    if len(names_set & BLUEPRINT_INDICATORS) >= 2:
        return True
    return False


def detect_blueprint_type(names_set):
    for cls in BLUEPRINT_CLASS_NAMES:
        if cls in names_set:
            return cls
    if names_set & BLUEPRINT_INDICATORS:
        return 'Blueprint'
    return 'Unknown'


ERROR_TEXT_KEYWORDS_CN = [
    '无效', '错误', '失败', '无法', '缺失', '未找到', '未解析',
    '编译', '不兼容', '已弃用', '被禁用',
]
ERROR_TEXT_KEYWORDS_EN = [
    'error', 'fail', 'cannot', 'unable', 'missing', 'invalid',
    'unresolved', 'broken', 'deprecated', 'incompatible',
    'is disabled', 'compile',
]


def find_error_strings(data, min_offset=0):
    """Search for UTF-16LE error text embedded in binary data."""
    errors = []
    warnings = []
    pos = min_offset
    while pos + 4 < len(data):
        slen = struct.unpack_from('<i', data, pos)[0]

        text = None
        if 10 < slen < 20000 and pos + 4 + slen <= len(data):
            raw = data[pos + 4:pos + 4 + slen]
            if raw[-1:] == b'\x00':
                try:
                    text = raw[:-1].decode('utf-8', errors='strict')
                except:
                    text = None
        elif -20000 < slen < -10 and pos + 4 + (-slen) * 2 <= len(data):
            actual = -slen
            raw = data[pos + 4:pos + 4 + actual * 2]
            if raw[-2:] == b'\x00\x00':
                try:
                    text = raw[:-2].decode('utf-16-le', errors='strict')
                except:
                    text = None

        if text and len(text) > 5:
            tl = text.lower()
            is_printable = all(c.isprintable() or c in '\n\r\t' for c in text)
            if is_printable:
                is_err = any(k in tl for k in ERROR_TEXT_KEYWORDS_EN) or \
                         any(k in text for k in ERROR_TEXT_KEYWORDS_CN)
                if is_err:
                    if '禁用' in text or 'disabled' in tl:
                        warnings.append(text.strip()[:500])
                    else:
                        errors.append(text.strip()[:500])
        pos += 1

    # Deduplicate
    seen = set()
    unique_errors = []
    for e in errors:
        key = e[:80]
        if key not in seen:
            seen.add(key)
            unique_errors.append(e)

    seen_w = set()
    unique_warnings = []
    for w in warnings:
        key = w[:80]
        if key not in seen_w:
            seen_w.add(key)
            unique_warnings.append(w)

    return unique_errors, unique_warnings


def check_blueprint(filepath):
    """
    Check a single .uasset file for Blueprint compilation status.

    Returns dict:
      is_blueprint: bool
      status: 'PASS' | 'ERROR' | 'WARNING' | 'UNKNOWN' | 'NOT_BLUEPRINT' | 'PARSE_ERROR'
      bp_type: str
      errors: list[str]
      warnings: list[str]
      details: str
    """
    result = {
        'file': str(filepath),
        'is_blueprint': False,
        'status': 'NOT_BLUEPRINT',
        'bp_type': '',
        'errors': [],
        'warnings': [],
        'details': '',
    }

    try:
        with open(filepath, 'rb') as f:
            data = f.read()
    except Exception as e:
        result['status'] = 'PARSE_ERROR'
        result['details'] = str(e)
        return result

    hdr = parse_uasset_header(data)
    if hdr is None:
        result['status'] = 'PARSE_ERROR'
        result['details'] = 'Invalid uasset header'
        return result

    if hdr['name_count'] <= 0 or hdr['name_count'] > 500000:
        result['status'] = 'PARSE_ERROR'
        result['details'] = f'Suspicious name count: {hdr["name_count"]}'
        return result

    names = parse_names(data, hdr['name_offset'], hdr['name_count'])
    names_set = set(names)

    if not is_blueprint(names_set):
        return result

    result['is_blueprint'] = True
    result['bp_type'] = detect_blueprint_type(names_set)

    has_compiler_msg = 'bHasCompilerMessage' in names_set
    has_error_props = 'ErrorMsg' in names_set and 'ErrorType' in names_set

    error_texts, warning_texts = [], []
    if has_compiler_msg or has_error_props:
        error_texts, warning_texts = find_error_strings(
            data, min_offset=max(0, hdr.get('export_offset', 0) - 100))

    result['errors'] = error_texts
    result['warnings'] = warning_texts

    if has_compiler_msg and (error_texts or has_error_props):
        result['status'] = 'ERROR'
        if error_texts:
            result['details'] = f'{len(error_texts)} error(s) detected'
        elif has_error_props:
            result['details'] = 'bHasCompilerMessage=true with ErrorMsg/ErrorType properties'
        else:
            result['details'] = 'bHasCompilerMessage=true'
    elif has_compiler_msg:
        result['status'] = 'WARNING'
        result['details'] = 'bHasCompilerMessage in name table (possible warnings/disabled nodes)'
    elif has_error_props:
        result['status'] = 'WARNING'
        result['details'] = 'ErrorMsg/ErrorType properties present'
    else:
        result['status'] = 'PASS'
        result['details'] = 'No compilation error indicators found'

    return result

# ---------------------------------------------------------------------------
# Batch scanner
# ---------------------------------------------------------------------------

def scan_directory(content_dir, progress_callback=None):
    content_path = Path(content_dir)
    uasset_files = sorted(content_path.rglob('*.uasset'))

    results = []
    blueprints_total = 0
    errors_total = 0
    warnings_total = 0

    for i, fpath in enumerate(uasset_files):
        if progress_callback and i % 100 == 0:
            progress_callback(i, len(uasset_files))

        r = check_blueprint(str(fpath))
        if r['is_blueprint']:
            blueprints_total += 1
            results.append(r)
            if r['status'] == 'ERROR':
                errors_total += 1
            elif r['status'] == 'WARNING':
                warnings_total += 1

    return {
        'total_assets': len(uasset_files),
        'total_blueprints': blueprints_total,
        'total_errors': errors_total,
        'total_warnings': warnings_total,
        'results': results,
    }


def generate_report(scan_result, output_path=None):
    lines = []
    lines.append('# Blueprint Compilation Status Report\n')
    lines.append(f'**Scan Time**: {time.strftime("%Y-%m-%d %H:%M:%S")}\n')
    lines.append(f'| Metric | Count |')
    lines.append(f'|--------|-------|')
    lines.append(f'| Total .uasset files scanned | {scan_result["total_assets"]} |')
    lines.append(f'| Blueprints detected | {scan_result["total_blueprints"]} |')
    lines.append(f'| Compilation ERRORS | {scan_result["total_errors"]} |')
    lines.append(f'| Compilation WARNINGS | {scan_result["total_warnings"]} |')
    lines.append(f'| Compiled successfully | {scan_result["total_blueprints"] - scan_result["total_errors"] - scan_result["total_warnings"]} |')
    lines.append('')

    error_results = [r for r in scan_result['results'] if r['status'] == 'ERROR']
    warn_results = [r for r in scan_result['results'] if r['status'] == 'WARNING']
    pass_results = [r for r in scan_result['results'] if r['status'] == 'PASS']

    if error_results:
        lines.append('## Blueprints with Compilation Errors\n')
        for r in error_results:
            rel = r['file']
            lines.append(f'### `{os.path.basename(rel)}`\n')
            lines.append(f'- **Path**: `{rel}`')
            lines.append(f'- **Type**: {r["bp_type"]}')
            lines.append(f'- **Status**: ERROR - {r["details"]}')
            if r['errors']:
                lines.append(f'- **Error Messages**:')
                for e in r['errors']:
                    lines.append(f'  - {e}')
            if r['warnings']:
                lines.append(f'- **Warnings**:')
                for w in r['warnings']:
                    lines.append(f'  - {w}')
            lines.append('')

    if warn_results:
        lines.append('## Blueprints with Warnings\n')
        for r in warn_results:
            rel = r['file']
            lines.append(f'- `{os.path.basename(rel)}` ({r["bp_type"]}) - {r["details"]}')
        lines.append('')

    if pass_results:
        lines.append('## Successfully Compiled Blueprints\n')
        lines.append(f'<details><summary>Show {len(pass_results)} passed Blueprints</summary>\n')
        for r in pass_results:
            lines.append(f'- `{os.path.basename(r["file"])}` ({r["bp_type"]})')
        lines.append('\n</details>\n')

    report = '\n'.join(lines)

    if output_path:
        with open(output_path, 'w', encoding='utf-8') as f:
            f.write(report)
        print(f'Report saved to: {output_path}')

    return report

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description='Check UE5 Blueprint compilation status')
    parser.add_argument('path', help='.uasset file path OR --scan directory')
    parser.add_argument('--scan', action='store_true',
                        help='Scan a directory for all Blueprints')
    parser.add_argument('--output', '-o', default=None,
                        help='Output report file path (for --scan mode)')
    args = parser.parse_args()

    if args.scan:
        content_dir = args.path
        if not os.path.isdir(content_dir):
            print(f'Error: {content_dir} is not a directory')
            sys.exit(1)

        print(f'Scanning: {content_dir}')
        def progress(i, total):
            print(f'  [{i}/{total}] scanning...', end='\r')

        result = scan_directory(content_dir, progress_callback=progress)
        print(f'\nScan complete: {result["total_blueprints"]} Blueprints found '
              f'({result["total_errors"]} errors, {result["total_warnings"]} warnings)')

        output = args.output
        if not output:
            output = os.path.join(content_dir, '..', 'blueprint_compile_report.md')
        report = generate_report(result, output)

        if result['total_errors'] > 0:
            print('\n=== BLUEPRINTS WITH ERRORS ===')
            for r in result['results']:
                if r['status'] == 'ERROR':
                    print(f'  FAIL: {os.path.basename(r["file"])} - {r["details"]}')
                    for e in r['errors'][:3]:
                        print(f'        {e[:150]}')

    else:
        filepath = args.path
        if not os.path.isfile(filepath):
            print(f'Error: {filepath} is not a file')
            sys.exit(1)

        r = check_blueprint(filepath)
        print(f'File: {filepath}')
        print(f'Is Blueprint: {r["is_blueprint"]}')
        if r['is_blueprint']:
            print(f'Blueprint Type: {r["bp_type"]}')
            status_icon = {'PASS': 'PASS', 'ERROR': 'FAIL', 'WARNING': 'WARN',
                           'UNKNOWN': '????', 'PARSE_ERROR': 'ERR!'}
            print(f'Compile Status: [{status_icon.get(r["status"], "????")}] {r["details"]}')
            if r['errors']:
                print(f'\nError Messages ({len(r["errors"])}):')
                for e in r['errors']:
                    print(f'  - {e}')
            if r['warnings']:
                print(f'\nWarnings ({len(r["warnings"])}):')
                for w in r['warnings']:
                    print(f'  - {w}')
        else:
            print(f'Status: Not a Blueprint asset')

        sys.exit(1 if r['status'] == 'ERROR' else 0)


if __name__ == '__main__':
    main()
