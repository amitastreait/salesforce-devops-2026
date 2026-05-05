#!/usr/bin/env python3
"""
sf_delta.py - Generate a Salesforce delta deployment package from two git commits.

Copies changed source files into a structured output directory and generates
package.xml for additions/modifications and destructiveChanges.xml for deletions.

Output layout:
    <output>/
      package/
        package.xml
        force-app/main/default/...   (changed source files)
      destructiveChanges/
        destructiveChanges.xml
        package.xml                  (empty - required by SF tooling)

Usage:
    python3 sf_delta.py --from <commit> --to <commit> [OPTIONS]

Examples:
    python3 sf_delta.py --from HEAD~2 --to HEAD
    python3 sf_delta.py --from HEAD~2 --to HEAD --output ./delta --api-version 66.0
    python3 sf_delta.py --from main --to HEAD --ignore-whitespace
"""

import argparse
import re
import shutil
import subprocess
import sys
from collections import defaultdict
from pathlib import Path
from xml.dom import minidom
import xml.etree.ElementTree as ET


# ── Suffix registry (longest first to avoid partial matches) ──────────────────

KNOWN_SUFFIXES = sorted([
    # Apex
    '.cls-meta.xml', '.cls',
    '.trigger-meta.xml', '.trigger',
    '.page-meta.xml',
    '.component-meta.xml',
    # Flows / Automation
    '.flow-meta.xml',
    '.approvalProcess-meta.xml',
    '.assignmentRules-meta.xml',
    '.autoResponseRules-meta.xml',
    '.escalationRules-meta.xml',
    '.workflow-meta.xml',
    '.sharingRules-meta.xml',
    '.pathAssistant-meta.xml',
    # UI
    '.flexipage-meta.xml',
    '.layout-meta.xml',
    '.tab-meta.xml',
    '.app-meta.xml',
    '.quickAction-meta.xml',
    '.brandingSet-meta.xml',
    '.network-meta.xml',
    '.notiftype-meta.xml',
    # Security / Access
    '.permissionset-meta.xml',
    '.permissionSetGroup-meta.xml',
    '.customPermission-meta.xml',
    '.role-meta.xml',
    '.group-meta.xml',
    '.queue-meta.xml',
    '.namedCredential-meta.xml',
    '.remoteSite-meta.xml',
    '.corsWhitelistOrigin-meta.xml',
    '.cspTrustedSite-meta.xml',
    # Data / Config
    '.globalValueSet-meta.xml',
    '.standardValueSet-meta.xml',
    '.md-meta.xml',
    '.labels-meta.xml',
    '.settings-meta.xml',
    '.translation-meta.xml',
    # Assets / Resources
    '.resource-meta.xml', '.resource',
    '.asset-meta.xml', '.asset',
    '.email-meta.xml', '.email',
    # Folders and folder-based content
    '.reportFolder-meta.xml',
    '.report-meta.xml',
    '.dashboardFolder-meta.xml',
    '.dashboard-meta.xml',
    '.folder-meta.xml',
    '.document-meta.xml',
    # Object sub-types
    '.object-meta.xml',
    '.field-meta.xml',
    '.validationRule-meta.xml',
    '.listView-meta.xml',
    '.compactLayout-meta.xml',
    '.webLink-meta.xml',
    '.recordType-meta.xml',
    '.businessProcess-meta.xml',
    '.fieldSet-meta.xml',
    '.sharingReason-meta.xml',
    '.index-meta.xml',
    '.searchLayout-meta.xml',
    # LWC meta descriptor
    '.js-meta.xml',
], key=len, reverse=True)


def strip_suffix(filename: str) -> str:
    """Remove the Salesforce source-format suffix from a filename."""
    for suffix in KNOWN_SUFFIXES:
        if filename.endswith(suffix):
            return filename[: -len(suffix)]
    return Path(filename).stem


# ── Metadata type registries ──────────────────────────────────────────────────

BUNDLE_TYPES = {
    'lwc':         'LightningComponentBundle',
    'aura':        'AuraDefinitionBundle',
    'experiences': 'ExperienceBundle',
}

SIMPLE_FOLDER_TYPES = {
    'classes':             'ApexClass',
    'triggers':            'ApexTrigger',
    'flows':               'Flow',
    'flexipages':          'FlexiPage',
    'layouts':             'Layout',
    'permissionsets':      'PermissionSet',
    'permissionSetGroups': 'PermissionSetGroup',
    'tabs':                'CustomTab',
    'applications':        'CustomApplication',
    'customMetadata':      'CustomMetadata',
    'groups':              'Group',
    'roles':               'Role',
    'queues':              'Queue',
    'staticresources':     'StaticResource',
    'contentassets':       'ContentAsset',
    'corsWhitelistOrigins':'CorsWhitelistOrigin',
    'cspTrustedSites':     'CspTrustedSite',
    'customPermissions':   'CustomPermission',
    'labels':              'CustomLabels',
    'settings':            'Settings',
    'pages':               'ApexPage',
    'components':          'ApexComponent',
    'workflows':           'Workflow',
    'assignmentRules':     'AssignmentRules',
    'autoResponseRules':   'AutoResponseRules',
    'escalationRules':     'EscalationRules',
    'approvalProcesses':   'ApprovalProcess',
    'quickActions':        'QuickAction',
    'globalValueSets':     'GlobalValueSet',
    'standardValueSets':   'StandardValueSet',
    'namedCredentials':    'NamedCredential',
    'remoteSiteSettings':  'RemoteSiteSetting',
    'sharingRules':        'SharingRules',
    'pathAssistants':      'PathAssistant',
    'notificationtypes':   'NotificationTypeConfig',
    'brandingSets':        'BrandingSet',
    'communities':         'Network',
    'translations':        'Translations',
    'territory2Models':    'Territory2Model',
    'territory2Types':     'Territory2Type',
    'territory2Rules':     'Territory2Rule',
}

FOLDER_BASED_TYPES = {
    'reports':        'Report',
    'dashboards':     'Dashboard',
    'documents':      'Document',
    'emailTemplates': 'EmailTemplate',
}

FOLDER_CONTAINER_TYPES = {
    'reports':        'ReportFolder',
    'dashboards':     'DashboardFolder',
    'documents':      'DocumentFolder',
    'emailTemplates': 'EmailFolder',
}

FOLDER_RECORD_SUFFIX = {
    'reports':        '.reportFolder-meta.xml',
    'dashboards':     '.dashboardFolder-meta.xml',
    'documents':      '.folder-meta.xml',
    'emailTemplates': '.folder-meta.xml',
}

OBJECT_SUB_TYPES = {
    'fields':            'CustomField',
    'validationRules':   'ValidationRule',
    'listViews':         'ListView',
    'compactLayouts':    'CompactLayout',
    'webLinks':          'WebLink',
    'recordTypes':       'RecordType',
    'businessProcesses': 'BusinessProcess',
    'fieldSets':         'FieldSet',
    'sharingReasons':    'SharingReason',
    'indexes':           'Index',
    'searchLayouts':     'SearchLayout',
}


# ── Ignore pattern matching ───────────────────────────────────────────────────

# Ignore files checked automatically (in order); first found wins per repo root.
DEFAULT_IGNORE_FILES = ['.sfignore', '.sgdignore', '.forceignore']


def _compile_ignore_pattern(raw: str):
    """
    Convert a single gitignore-style line to a compiled regex.
    Returns None for blank lines and comments.

    Rules implemented:
      - Lines starting with # are comments
      - Trailing / marks a directory pattern (match file anywhere inside)
      - ** matches any number of path segments (including zero)
      - *  matches any sequence of chars within a single segment
      - ?  matches any single char within a segment
      - No leading /  → pattern can match at any depth
      - Leading /     → pattern anchored to the source root
    """
    p = raw.strip()
    if not p or p.startswith('#'):
        return None

    is_dir = p.endswith('/')
    p = p.rstrip('/')
    root_anchored = p.startswith('/')
    if root_anchored:
        p = p[1:]

    # Convert glob to regex token by token
    tokens: list[str] = []
    i = 0
    while i < len(p):
        c = p[i]
        if c == '*' and i + 1 < len(p) and p[i + 1] == '*':
            tokens.append('.*')          # ** → anything including /
            i += 2
            if i < len(p) and p[i] == '/':
                tokens.append('/?')      # consume the separator greedily
                i += 1
        elif c == '*':
            tokens.append('[^/]*')       # * → anything within one segment
            i += 1
        elif c == '?':
            tokens.append('[^/]')        # ? → any single char within segment
            i += 1
        else:
            tokens.append(re.escape(c))
            i += 1

    body = ''.join(tokens)

    # Anchoring logic
    has_separator = '/' in p          # literal / present after stripping leading /
    if root_anchored or has_separator:
        # Rooted or path-specific: must match from the path start
        regex = f'^{body}'
    else:
        # Simple name pattern: match at any depth (basename or any segment)
        regex = f'(^|/){body}'

    regex += r'(/.*)?$' if is_dir else r'$'

    try:
        return re.compile(regex)
    except re.error:
        return None


def load_ignore_patterns(ignore_files: list) -> list:
    """
    Read and compile patterns from a list of ignore file Paths.
    Skips files that don't exist.
    Returns a list of (pattern_string, compiled_regex) tuples.
    """
    compiled: list[tuple[str, re.Pattern]] = []
    for path in ignore_files:
        if not path.exists():
            continue
        for line in path.read_text(encoding='utf-8').splitlines():
            rx = _compile_ignore_pattern(line)
            if rx is not None:
                compiled.append((line.strip(), rx))
    return compiled


def is_ignored(file_path: str, patterns: list) -> bool:
    """Return True if file_path matches any compiled ignore pattern."""
    fp = file_path.replace('\\', '/')
    return any(rx.search(fp) is not None for _, rx in patterns)


# ── File classification ───────────────────────────────────────────────────────

def classify_file(file_path: str, source_root: str):
    """
    Map a repo-relative file path to (metadata_type, member_name).
    Returns None for files outside the source root or unrecognised types.
    """
    path = Path(file_path)
    try:
        inner = path.relative_to(source_root)
    except ValueError:
        return None

    parts = inner.parts
    if not parts:
        return None

    folder = parts[0]

    # ── Bundle types: LWC, Aura, ExperienceBundle ─────────────────────────────
    if folder in BUNDLE_TYPES:
        if len(parts) < 2:
            return None
        return (BUNDLE_TYPES[folder], parts[1])

    # ── Custom Objects and their sub-components ───────────────────────────────
    if folder == 'objects':
        if len(parts) < 3:
            return None
        object_name = parts[1]
        if len(parts) == 3:
            if parts[2].endswith('.object-meta.xml'):
                return ('CustomObject', object_name)
            return None
        sub_folder = parts[2]
        filename   = parts[3]
        if sub_folder in OBJECT_SUB_TYPES:
            member = f"{object_name}.{strip_suffix(filename)}"
            return (OBJECT_SUB_TYPES[sub_folder], member)
        return ('CustomObject', object_name)

    # ── Static resources (can be a folder of files) ───────────────────────────
    if folder == 'staticresources':
        if len(parts) == 2:
            return ('StaticResource', strip_suffix(parts[1]))
        if len(parts) >= 3:
            return ('StaticResource', parts[1])
        return None

    # ── Folder-based types: reports, dashboards, documents, emailTemplates ────
    if folder in FOLDER_BASED_TYPES:
        if len(parts) == 2:
            filename = parts[1]
            folder_suffix = FOLDER_RECORD_SUFFIX.get(folder, '')
            if folder_suffix and filename.endswith(folder_suffix):
                return (FOLDER_CONTAINER_TYPES[folder], strip_suffix(filename))
            return (FOLDER_BASED_TYPES[folder], strip_suffix(filename))
        if len(parts) == 3:
            sub_folder, filename = parts[1], parts[2]
            member = f"{sub_folder}/{strip_suffix(filename)}"
            return (FOLDER_BASED_TYPES[folder], member)
        return None

    # ── Simple single-folder types ────────────────────────────────────────────
    if folder in SIMPLE_FOLDER_TYPES:
        if len(parts) < 2:
            return None
        return (SIMPLE_FOLDER_TYPES[folder], strip_suffix(parts[1]))

    return None


# ── File collection helpers ───────────────────────────────────────────────────

def find_bundle_files(source_file: Path) -> list:
    """Return all files in the component bundle directory."""
    bundle_dir = source_file.parent
    if bundle_dir.is_dir():
        return [f for f in bundle_dir.rglob('*') if f.is_file()]
    return [source_file] if source_file.is_file() else []


def find_companion_file(source_file: Path):
    """
    Return the companion -meta.xml for a source file, or the base source file
    for a -meta.xml descriptor, if it exists on disk.
    """
    name   = source_file.name
    parent = source_file.parent
    if name.endswith('-meta.xml'):
        base = parent / name[:-9]
        return base if base.exists() else None
    meta = parent / (name + '-meta.xml')
    return meta if meta.exists() else None


# ── Git helpers ───────────────────────────────────────────────────────────────

def validate_commit(repo_root: str, commit: str) -> bool:
    result = subprocess.run(
        ['git', 'rev-parse', '--verify', commit],
        capture_output=True, text=True, cwd=repo_root,
    )
    return result.returncode == 0


def get_changed_files(
    repo_root: str,
    from_commit: str,
    to_commit: str,
    source_dir: str = '',
    ignore_whitespace: bool = False,
) -> list:
    """
    Returns [(status, filepath)] from git diff.
    status is one of: 'A' (added), 'M' (modified), 'D' (deleted).
    Renames are expanded into a delete of the old path + add of the new path.
    When source_dir is provided it is passed as a pathspec so git only
    reports changes under that directory.
    """
    cmd = ['git', 'diff', '--name-status']
    if ignore_whitespace:
        cmd.append('-w')
    cmd += [from_commit, to_commit]
    if source_dir:
        cmd += ['--', source_dir]    # pathspec: limit diff to this subtree

    result = subprocess.run(cmd, capture_output=True, text=True, cwd=repo_root)
    if result.returncode != 0:
        print(f"ERROR: git diff failed:\n{result.stderr}", file=sys.stderr)
        sys.exit(1)

    changes = []
    for line in result.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts       = line.split('\t')
        status_code = parts[0][0]    # first char: A, M, D, R, C, T, U

        if status_code in ('A', 'M', 'T'):
            changes.append(('A' if status_code == 'A' else 'M', parts[-1]))
        elif status_code == 'D':
            changes.append(('D', parts[1]))
        elif status_code in ('R', 'C') and len(parts) >= 3:
            changes.append(('D', parts[1]))    # old path → deleted
            changes.append(('A', parts[2]))    # new path → added
    return changes


# ── XML generation ────────────────────────────────────────────────────────────

def build_package_xml(members_by_type: dict, api_version: str) -> str:
    """Return a formatted package.xml / destructiveChanges.xml string."""
    package = ET.Element('Package')
    package.set('xmlns', 'http://soap.sforce.com/2006/04/metadata')

    for meta_type in sorted(members_by_type):
        members    = sorted(members_by_type[meta_type])
        types_elem = ET.SubElement(package, 'types')
        for member in members:
            m      = ET.SubElement(types_elem, 'members')
            m.text = member
        n      = ET.SubElement(types_elem, 'name')
        n.text = meta_type

    v      = ET.SubElement(package, 'version')
    v.text = api_version

    rough = ET.tostring(package, encoding='unicode')
    dom   = minidom.parseString(rough)
    lines = dom.toprettyxml(indent='    ').split('\n')
    lines[0] = '<?xml version="1.0" encoding="UTF-8"?>'
    return '\n'.join(lines)


# ── Core delta logic ──────────────────────────────────────────────────────────

def generate_delta(args):
    repo_root   = Path(args.repo_root).resolve()
    output_dir  = Path(args.output).resolve()
    source_root = args.source_dir.rstrip('/')
    api_version = args.api_version

    # Validate commits
    for commit in (args.from_commit, args.to_commit):
        if not validate_commit(str(repo_root), commit):
            print(f"ERROR: commit '{commit}' not found in {repo_root}", file=sys.stderr)
            sys.exit(1)

    # ── Resolve ignore files ──────────────────────────────────────────────────
    ignore_paths: list[Path] = []
    if not args.no_ignore:
        # Auto-detect standard ignore files in repo root
        for name in DEFAULT_IGNORE_FILES:
            candidate = repo_root / name
            if candidate.exists():
                ignore_paths.append(candidate)
        # User-supplied extra file(s)
        for extra in (args.ignore_file or []):
            p = Path(extra)
            if not p.is_absolute():
                p = repo_root / p
            if p.exists():
                ignore_paths.append(p)
            else:
                print(f"  [WARN] ignore file not found: {p}", file=sys.stderr)

    ignore_patterns = load_ignore_patterns(ignore_paths)

    # ── Print run header ─────────────────────────────────────────────────────
    print(f"Repository        : {repo_root}")
    print(f"Diff range        : {args.from_commit}..{args.to_commit}")
    print(f"Source root       : {source_root}")
    print(f"Output dir        : {output_dir}")
    print(f"API version       : {api_version}")
    print(f"Ignore whitespace : {'yes (-w)' if args.ignore_whitespace else 'no'}")
    if ignore_paths:
        print(f"Ignore files      : {', '.join(str(p.name) for p in ignore_paths)}"
              f"  ({len(ignore_patterns)} patterns)")
    else:
        print(f"Ignore files      : none")
    print()

    # ── Collect changed files ─────────────────────────────────────────────────
    all_changes = get_changed_files(
        str(repo_root),
        args.from_commit,
        args.to_commit,
        source_dir=source_root,
        ignore_whitespace=args.ignore_whitespace,
    )
    upserted = [(s, p) for s, p in all_changes if s in ('A', 'M')]
    deleted  = [(s, p) for s, p in all_changes if s == 'D']

    print(f"Git changes       : {len(upserted)} added/modified, {len(deleted)} deleted")
    print()

    # ── Classify each file ────────────────────────────────────────────────────
    upsert_members:   dict = defaultdict(set)
    delete_members:   dict = defaultdict(set)
    files_to_copy:    set  = set()
    processed_bundles: set = set()
    skipped:  list = []
    ignored:  list = []

    for _status, file_path in upserted:
        if ignore_patterns and is_ignored(file_path, ignore_patterns):
            ignored.append(file_path)
            continue

        result = classify_file(file_path, source_root)
        if result is None:
            skipped.append(file_path)
            continue

        meta_type, member = result
        upsert_members[meta_type].add(member)

        src = repo_root / file_path
        if not src.exists():
            print(f"  [WARN] file not found on disk: {file_path}")
            continue

        if meta_type in ('LightningComponentBundle', 'AuraDefinitionBundle', 'ExperienceBundle'):
            bundle_key = f"{meta_type}:{member}"
            if bundle_key not in processed_bundles:
                processed_bundles.add(bundle_key)
                files_to_copy.update(find_bundle_files(src))
        else:
            files_to_copy.add(src)
            companion = find_companion_file(src)
            if companion:
                files_to_copy.add(companion)

    for _status, file_path in deleted:
        if ignore_patterns and is_ignored(file_path, ignore_patterns):
            ignored.append(file_path)
            continue

        result = classify_file(file_path, source_root)
        if result is None:
            continue
        meta_type, member = result
        delete_members[meta_type].add(member)

    # ── Create output directories ─────────────────────────────────────────────
    #
    # Layout:
    #   <output>/package/package.xml          ← manifest for added/modified
    #   <output>/delta/force-app/...          ← copied source files
    #   <output>/destructiveChanges/
    #       destructiveChanges.xml            ← deleted components
    #       package.xml                       ← empty (required by SF tooling)
    #
    package_dir     = output_dir / 'package'
    delta_dir       = output_dir
    destructive_dir = output_dir / 'destructiveChanges'
    package_dir.mkdir(parents=True, exist_ok=True)

    # ── Copy source files into delta/ ─────────────────────────────────────────
    copied = 0
    for src_file in sorted(files_to_copy):
        try:
            rel = src_file.relative_to(repo_root)
        except ValueError:
            continue
        dest = delta_dir / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src_file, dest)
        copied += 1

    # ── Write package/package.xml ─────────────────────────────────────────────
    if upsert_members:
        pkg_xml_path = package_dir / 'package.xml'
        pkg_xml_path.write_text(
            build_package_xml(dict(upsert_members), api_version),
            encoding='utf-8',
        )

    # ── Write destructiveChanges/ ─────────────────────────────────────────────
    if delete_members:
        destructive_dir.mkdir(parents=True, exist_ok=True)
        (destructive_dir / 'package.xml').write_text(
            build_package_xml({}, api_version),
            encoding='utf-8',
        )
        (destructive_dir / 'destructiveChanges.xml').write_text(
            build_package_xml(dict(delete_members), api_version),
            encoding='utf-8',
        )

    # ── Print summary ─────────────────────────────────────────────────────────
    print("=" * 60)
    print("DELTA SUMMARY")
    print("=" * 60)

    if upsert_members:
        print(f"\npackage/package.xml  ({copied} files copied)")
        for meta_type in sorted(upsert_members):
            for member in sorted(upsert_members[meta_type]):
                print(f"  + [{meta_type}]  {member}")
    else:
        print("\nNo added/modified Salesforce metadata components detected.")

    if delete_members:
        print(f"\ndestructiveChanges/destructiveChanges.xml")
        for meta_type in sorted(delete_members):
            for member in sorted(delete_members[meta_type]):
                print(f"  - [{meta_type}]  {member}")

    if ignored:
        print(f"\nIgnored ({len(ignored)} files matched ignore patterns):")
        for f in ignored:
            print(f"  ∅ {f}")

    if skipped:
        print(f"\nSkipped ({len(skipped)} non-metadata files):")
        for f in skipped:
            print(f"  ~ {f}")

    if not upsert_members and not delete_members:
        print("\nNo Salesforce metadata changes found between the two commits.")
        return

    print(f"\nOutput written to: {output_dir}/")


# ── Usage guide ──────────────────────────────────────────────────────────────

def show_usage():
    print("""
╔══════════════════════════════════════════════════════════════════╗
║              sf_delta.py  —  Salesforce Delta Generator          ║
╚══════════════════════════════════════════════════════════════════╝

Compares two git commits, copies every changed Salesforce source file
into an output directory (preserving the DX project structure), and
generates package.xml for additions/modifications plus
destructiveChanges.xml for deletions.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 SYNTAX
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  python3 sf_delta.py --from <commit> --to <commit> [OPTIONS]

  --from  Older commit reference  (what you're diffing FROM)
  --to    Newer commit reference  (what you're diffing TO)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 OPTIONS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  --from <ref>              Base (older) commit. Required.
  --to   <ref>              Target (newer) commit. Required.

  -o / --output <dir>       Where to write the delta package.
                            Default: ./delta_output

  --source-dir <path>       Salesforce source root inside the repo.
                            Default: force-app/main/default

  --api-version <version>   API version written into package.xml.
                            Default: 66.0

  --repo-root <path>        Path to the git repo root.
                            Default: . (current directory)

  --ignore-whitespace       Pass -w to git diff — treats whitespace-only
                            changes as non-changes. Useful when formatters
                            or CI tools alter indentation.

  --ignore-file <path>      Additional ignore file (gitignore-style patterns).
                            Can be specified multiple times.
                            Auto-detected files are still loaded unless
                            --no-ignore is set.

  --no-ignore               Disable all ignore file loading (auto-detected
                            and --ignore-file). Every changed file is
                            included in the delta.

  --examples                Print this usage guide and exit.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 IGNORE FILES
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  The script automatically loads the following files from the repo
  root if they exist (checked in order):

    .sfignore       sf_delta-specific exclusions (highest priority)
    .sgdignore      sfdx-git-delta exclusions
    .forceignore    standard Salesforce DX exclusions

  All three are merged — a file matching any pattern in any loaded
  ignore file is excluded from the delta.

  Pattern syntax (gitignore-style):
    #                  Comment line — ignored
    package.xml        Match this filename at any depth
    /package.xml       Match only at the repo root
    src/               Match the 'src' directory and everything inside
    **/jsconfig.json   Match jsconfig.json at any depth
    **/__tests__/**    Match any file inside a __tests__ directory
    *.cls-meta.xml     Match any file ending with .cls-meta.xml

  Example .sfignore:
    # Exclude Jest test files from delta
    **/__tests__/**
    # Exclude LWC config files (not deployable)
    **/jsconfig.json
    **/.eslintrc.json
    # Exclude specific flows managed by another team
    force-app/main/default/flows/Legacy_Flow.flow-meta.xml

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 COMMON EXAMPLES
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  1. Last two commits on the current branch:

       python3 sf_delta.py --from HEAD~1 --to HEAD

  2. Last three commits, custom output folder:

       python3 sf_delta.py --from HEAD~3 --to HEAD --output ./delta

  3. Compare a feature branch to main:

       python3 sf_delta.py --from main --to HEAD --output ./delta

  4. Compare two specific commit SHAs:

       python3 sf_delta.py --from a1b2c3d --to e4f5g6h --output ./delta

  5. Ignore whitespace-only changes (e.g. after running Prettier):

       python3 sf_delta.py --from HEAD~1 --to HEAD --ignore-whitespace

  6. Add a custom ignore file on top of the auto-detected ones:

       python3 sf_delta.py --from HEAD~1 --to HEAD \\
           --ignore-file ./scripts/my-delta-ignore.txt

  7. Run with no ignore files at all:

       python3 sf_delta.py --from HEAD~1 --to HEAD --no-ignore

  8. Run from outside the repo directory:

       python3 sf_delta.py --from HEAD~1 --to HEAD \\
           --repo-root /path/to/repo \\
           --output /path/to/output

  9. Override API version:

       python3 sf_delta.py --from HEAD~1 --to HEAD --api-version 65.0

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 OUTPUT STRUCTURE
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  <output>/
  ├── package/
  │   └── package.xml                  ← manifest for added / modified
  ├── force-app/main/default/          ← copied source files
  │   ├── classes/
  │   │   ├── MyClass.cls
  │   │   └── MyClass.cls-meta.xml
  │   ├── lwc/
  │   │   └── myComponent/             ← full bundle always copied
  │   │       ├── myComponent.js
  │   │       ├── myComponent.html
  │   │       └── myComponent.js-meta.xml
  │   └── flows/
  │       └── My_Flow.flow-meta.xml
  └── destructiveChanges/              ← only created when files are deleted
      ├── destructiveChanges.xml       ← deleted components
      └── package.xml                  ← empty (required by SF tooling)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 DEPLOY THE DELTA WITH SF CLI
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  # Deploy added/modified components
  sf project deploy start \\
      --manifest delta/package/package.xml \\
      --source-dir delta/package/force-app \\
      --target-org <alias>

  # Deploy deletions (run after the additions deploy)
  sf project deploy start \\
      --manifest delta/destructiveChanges/destructiveChanges.xml \\
      --post-destructive-changes \\
      --target-org <alias>

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 SUPPORTED METADATA TYPES
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Apex             ApexClass, ApexTrigger, ApexPage, ApexComponent
  Automation       Flow, Workflow, ApprovalProcess, AssignmentRules,
                   AutoResponseRules, EscalationRules, SharingRules,
                   PathAssistant
  UI               FlexiPage, Layout, CustomTab, CustomApplication,
                   QuickAction, BrandingSet
  Objects          CustomObject, CustomField, ValidationRule,
                   ListView, CompactLayout, RecordType, WebLink,
                   BusinessProcess, FieldSet
  Components       LightningComponentBundle, AuraDefinitionBundle,
                   ExperienceBundle
  Security         PermissionSet, PermissionSetGroup, CustomPermission,
                   Role, Group, Queue, NamedCredential, RemoteSiteSetting,
                   CorsWhitelistOrigin, CspTrustedSite
  Data / Config    CustomMetadata, GlobalValueSet, StandardValueSet,
                   CustomLabels, Settings, Translations
  Assets           StaticResource, ContentAsset, EmailTemplate
  Reports          Report, ReportFolder, Dashboard, DashboardFolder
""")


# ── CLI ───────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description='Generate a Salesforce delta package from two git commits.',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog='Run with --examples for a full usage guide.',
    )
    parser.add_argument('--from', dest='from_commit', metavar='<ref>',
                        help='Base (older) commit reference, e.g. HEAD~2 or main')
    parser.add_argument('--to', dest='to_commit', metavar='<ref>',
                        help='Target (newer) commit reference, e.g. HEAD or feature/my-branch')
    parser.add_argument('--output', '-o', default='./delta_output', metavar='<dir>',
                        help='Output directory (default: ./delta_output)')
    parser.add_argument('--source-dir', default='force-app/main/default', metavar='<path>',
                        help='Salesforce source root relative to repo root '
                             '(default: force-app/main/default)')
    parser.add_argument('--api-version', default='66.0', metavar='<version>',
                        help='Salesforce API version for package.xml (default: 66.0)')
    parser.add_argument('--repo-root', default='.', metavar='<path>',
                        help='Path to the git repository root (default: .)')
    parser.add_argument('--ignore-whitespace', action='store_true',
                        help='Pass -w to git diff: ignore whitespace-only changes')
    parser.add_argument('--ignore-file', action='append', metavar='<path>',
                        help='Additional ignore file (gitignore-style). '
                             'Can be specified multiple times. '
                             'Auto-detected files (.sfignore, .sgdignore, .forceignore) '
                             'are still loaded unless --no-ignore is set.')
    parser.add_argument('--no-ignore', action='store_true',
                        help='Disable all ignore file loading (auto-detected and --ignore-file)')
    parser.add_argument('--examples', action='store_true',
                        help='Show detailed usage guide and exit')

    args = parser.parse_args()

    if args.examples:
        show_usage()
        return

    if not args.from_commit or not args.to_commit:
        parser.error('--from and --to are required  (run --examples to see usage)')

    generate_delta(args)


if __name__ == '__main__':
    main()
