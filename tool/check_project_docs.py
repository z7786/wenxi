"""Check local links in maintained entry documents (no network or Markdown dependency)."""
import argparse
from pathlib import Path
import re
import unicodedata
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parent.parent
ENTRY_DOCS = (
    'AGENTS.md', 'README.md', 'CONTRIBUTING.md', 'docs/README.md',
    'docs/DEVELOPMENT.md', 'docs/BUILDING.md', 'docs/GITHUB-PUBLISH.md',
)
LINK = re.compile(r'\]\(\s*(?:<([^>]+)>|([^\s)]+))(?:\s+["\'][^\n]*?["\'])?\s*\)')


def without_fences(text):
    # Preserve line numbers while ignoring illustrative links in code blocks.
    output, fence = [], None
    for line in text.splitlines():
        match = re.match(r'^\s{0,3}(`{3,}|~{3,})', line)
        if match and fence is None:
            fence = match[1]
            output.append('')
        elif match and fence and match[1][0] == fence[0] and len(match[1]) >= len(fence):
            fence = None
            output.append('')
        else:
            output.append('' if fence else line)
    return '\n'.join(output)


def heading_anchors(text):
    anchors, counts = set(), {}
    for match in re.finditer(r'^ {0,3}#{1,6}\s+(.+?)\s*#*\s*$', without_fences(text), re.M):
        label = re.sub(r'<[^>]+>', '', match[1]).lower()
        label = ''.join(c for c in label if c in '-_ ' or unicodedata.category(c)[0] in 'LNM')
        slug = label.replace(' ', '-')
        count = counts.get(slug, 0)
        counts[slug] = count + 1
        anchors.add(f'{slug}-{count}' if count else slug)
    anchors.update(re.findall(r'\bid=["\']([^"\']+)["\']', text))
    return anchors


def check(root, documents=ENTRY_DOCS):
    root = Path(root).resolve()
    problems = []
    for name in documents:
        source = root / name
        if not source.is_file():
            problems.append(f'{name}: missing entry document')
            continue
        content = without_fences(source.read_text(encoding='utf-8-sig'))
        for match in LINK.finditer(content):
            target = match[1] or match[2]
            uri = urlsplit(target)
            if uri.scheme or uri.netloc:
                continue
            line = content[:match.start()].count('\n') + 1
            path = (source.parent / unquote(uri.path)).resolve() if uri.path else source.resolve()
            issue = None
            if root != path and root not in path.parents:
                issue = 'link leaves the project'
            elif not path.exists():
                issue = 'missing local target'
            elif uri.fragment and path.is_file() and path.suffix.lower() == '.md':
                anchors = heading_anchors(path.read_text(encoding='utf-8-sig'))
                if unquote(uri.fragment) not in anchors:
                    issue = 'missing Markdown heading'
            if issue:
                problems.append(f'{name}:{line}: {issue}: {target}')
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=ROOT)
    args = parser.parse_args()
    try:
        problems = check(args.root)
    except (OSError, ValueError) as error:
        parser.exit(1, f'Documentation check failed: {error}\n')
    if problems:
        print('\n'.join(problems))
        return 1
    print(f'Documentation links verified in {len(ENTRY_DOCS)} maintained entry documents.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
