#!/usr/bin/env python3
"""用现有 TypeScript 编译器生成本地开发 VSIX，不安装依赖或扩展。"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]
EXTENSION = ROOT / 'Sources/XIslandVSCode'
NS = 'http://schemas.microsoft.com/developer/vsx-schema/2011'


def package(output: Path, node: str) -> None:
    compiler = EXTENSION / 'node_modules/typescript/bin/tsc'
    if not compiler.is_file():
        raise SystemExit('缺少项目 TypeScript 依赖；请先在 Sources/XIslandVSCode 安装锁定的开发依赖。')
    subprocess.run([node, str(compiler), '-p', str(EXTENSION)], check=True)
    metadata = json.loads((EXTENSION / 'package.json').read_text())
    for key in ['name', 'publisher']:
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9-]*', metadata[key]):
            raise ValueError('Invalid manifest identity')
    files = {'extension/package.json': (EXTENSION / 'package.json').read_bytes(),
             'extension/README.md': (EXTENSION / 'README.md').read_bytes(),
             'extension/LICENSE': (ROOT / 'LICENSE').read_bytes()}
    for folder, extensions in [('out', {'.js', '.map'}), ('src', {'.ts'})]:
        for source in sorted((EXTENSION / folder).glob('*')):
            if source.is_file() and source.suffix in extensions:
                files['extension/' + source.relative_to(EXTENSION).as_posix()] = source.read_bytes()
    entry = 'extension/' + metadata['main'].removeprefix('./')
    if entry not in files or '..' in Path(entry).parts:
        raise ValueError('Manifest entry point is not packaged')
    ET.register_namespace('', NS)
    manifest = ET.Element(f'{{{NS}}}PackageManifest', Version='2.0.0')
    section = ET.SubElement(manifest, 'Metadata')
    ET.SubElement(section, 'Identity', Language='en-US', Id=metadata['name'], Version=metadata['version'], Publisher=metadata['publisher'])
    for tag, text in [('DisplayName', metadata['displayName']), ('Description', metadata['description']),
                      ('Tags', 'AI,observer'), ('Categories', ','.join(metadata.get('categories', []))), ('GalleryFlags', '')]:
        ET.SubElement(section, tag).text = text
    properties = ET.SubElement(section, 'Properties')
    for key, value in {'Microsoft.VisualStudio.Code.Engine': metadata['engines']['vscode'],
                       'Microsoft.VisualStudio.Code.ExtensionKind': 'workspace',
                       'Microsoft.VisualStudio.Code.ExecutesCode': 'true',
                       'Microsoft.VisualStudio.Services.Content.Pricing': 'Free',
                       'Microsoft.VisualStudio.Services.GitHubFlavoredMarkdown': 'true'}.items():
        ET.SubElement(properties, 'Property', Id=key, Value=value)
    ET.SubElement(section, 'License').text = 'extension/LICENSE'
    ET.SubElement(ET.SubElement(manifest, 'Installation'), 'InstallationTarget', Id='Microsoft.VisualStudio.Code')
    ET.SubElement(manifest, 'Dependencies')
    assets = ET.SubElement(manifest, 'Assets')
    for kind, path in [('Microsoft.VisualStudio.Code.Manifest', 'extension/package.json'),
                       ('Microsoft.VisualStudio.Services.Content.Details', 'extension/README.md'),
                       ('Microsoft.VisualStudio.Services.Content.License', 'extension/LICENSE')]:
        ET.SubElement(assets, 'Asset', Type=kind, Path=path, Addressable='true')
    files['extension.vsixmanifest'] = ET.tostring(manifest, encoding='utf-8', xml_declaration=True)
    types = ET.Element('Types', xmlns='http://schemas.openxmlformats.org/package/2006/content-types')
    for extension, mime in {'.json': 'application/json', '.js': 'application/javascript', '.map': 'application/json',
                            '.ts': 'text/plain', '.md': 'text/markdown', '.vsixmanifest': 'text/xml'}.items():
        ET.SubElement(types, 'Default', Extension=extension, ContentType=mime)
    ET.SubElement(types, 'Override', PartName='/extension/LICENSE', ContentType='text/plain')
    files['[Content_Types].xml'] = ET.tostring(types, encoding='utf-8', xml_declaration=True)
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        for name, content in sorted(files.items()):
            item = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
            item.compress_type = zipfile.ZIP_DEFLATED
            item.external_attr = 0o100644 << 16
            archive.writestr(item, content)
    print(f'VSIX: {output} ({len(files)} files); not installed or published')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / '.build/xisland-vscode-dev.vsix')
    parser.add_argument('--node', default='/opt/homebrew/bin/node' if Path('/opt/homebrew/bin/node').exists() else shutil.which('node'))
    args = parser.parse_args()
    if not args.node:
        raise SystemExit('Node.js is required')
    package(args.output, args.node)
