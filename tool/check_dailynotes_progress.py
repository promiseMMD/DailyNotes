#!/usr/bin/env python3
"""Check progress arithmetic; this does not verify the implementation claims."""

import argparse
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_PROGRESS = ROOT / 'docs' / 'DEVELOPMENT_PROGRESS.md'
SECTIONS = {
    'spec': '## 整份规范的证据建档进度',
    'editor': '## 手机文本编辑器：已跟踪的 13 项验收点',
    'clipboard': '## 剪贴板安全内核：已跟踪的 8 项验收点',
    'aa': '## Aa 排版与插入：已跟踪的 7 项验收点',
    'archive': '## 归档管理：已跟踪的 9 项验收点',
}


def section(text: str, heading: str) -> str:
    parts = text.split(heading)
    if len(parts) != 2:
        raise ValueError(f'缺少或重复章节：{heading}')
    return parts[1].split('\n## ', 1)[0]


def numbers_and_bar(content: str) -> tuple[int, int, float, str]:
    match = re.search(
        r'\*\*(\d+)\s*/\s*(\d+)(?:（([\d.]+)%）)?\*\*'
        r'\s*`\[([█░]+)\](?:\s*([\d.]+)%)?`',
        content,
    )
    if not match:
        raise ValueError('无法识别进度数值和进度条')
    done, total = int(match[1]), int(match[2])
    percentage = match[3] or match[5]
    if percentage is None or total <= 0 or done > total:
        raise ValueError('进度数值无效')
    percent = float(percentage)
    if abs(percent - done * 100 / total) > 0.051:
        raise ValueError(f'百分比与 {done}/{total} 不一致')
    bar = match[4]
    if bar.count('█') != round(done * len(bar) / total):
        raise ValueError(f'进度条与 {done}/{total} 不一致')
    if bar != '█' * bar.count('█') + '░' * bar.count('░'):
        raise ValueError('进度条必须先显示已完成部分')
    return done, total, percent, bar


def rows(content: str) -> list[list[str]]:
    result = []
    for line in content.splitlines():
        if not line.startswith('| '):
            continue
        cells = [cell.strip() for cell in line.strip().strip('|').split('|')]
        if (
            len(cells) == 3
            and cells[0] not in {'项目', '规范编号'}
            and not re.fullmatch(r':?-{3,}:?', cells[0])
        ):
            result.append(cells)
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--progress', type=Path, default=DEFAULT_PROGRESS)
    parser.add_argument('--spec', type=Path, help='本地规范 Markdown 文件')
    args = parser.parse_args()
    try:
        text = args.progress.read_text(encoding='utf-8')
        parts = {key: section(text, heading) for key, heading in SECTIONS.items()}
        spec_done, spec_total, _, _ = numbers_and_bar(parts['spec'])
        entries = rows(parts['spec'])
        ids = [row[0] for row in entries]
        if len(ids) != spec_done or len(set(ids)) != len(ids):
            raise ValueError('规范建档条目数量或编号重复')
        if any(not re.fullmatch(r'DN-\d{3}', value) for value in ids):
            raise ValueError('规范建档编号格式无效')
        if args.spec:
            spec = args.spec.read_text(encoding='utf-8')
            all_ids = {
                f'DN-{int(value):03d}'
                for value in re.findall(r'DN[-‐‑–—]?\s*(\d{1,3})', spec)
            }
            if len(all_ids) != spec_total or not set(ids).issubset(all_ids):
                raise ValueError('规范分母或已建档编号与本地规范不一致')
        for key in ('editor', 'clipboard', 'aa', 'archive'):
            done, total, _, _ = numbers_and_bar(parts[key])
            table_rows = rows(parts[key])
            complete = sum('已实现并自动化测试' in row[1] for row in table_rows)
            if len(table_rows) != total or complete != done:
                raise ValueError(f'{key} 的表格状态与进度数值不一致')
        print(f'进度统计一致：规范建档 {spec_done}/{spec_total}；编辑器、剪贴板、Aa 及归档表格一致。')
        print('统计一致不等于代码、真机或用户验收通过。')
        return 0
    except (OSError, UnicodeError, ValueError) as error:
        print(f'进度检查失败：{error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
