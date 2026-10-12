from pathlib import Path


def replace(path: str, old: str, new: str, count: int = 1) -> None:
    file = Path(path)
    text = file.read_text()
    assert text.count(old) == count, f"Unexpected source for {path}: {old!r}"
    file.write_text(text.replace(old, new))


root = 'windows/tauri/src/extensions/document-encodings/'
replace(root + 'common-encodings-plugin.test.ts', '.at(-1)', '.slice(-1)[0]')
replace(root + 'document-encoding-registry.test.ts', '.at(-1)', '.slice(-1)[0]', 2)
replace(root + 'document-encoding-registry.ts', '.every((alias) =>', '.every((alias: unknown) =>')
replace('docs/development/document-encoding.md', '当前支持 `none` 和 `utf8`', '支持 `none`、`utf8`、`utf16le` 和 `utf16be`')
replace('Plugins/win/Official/CommonEncodings/README.md',
        'cargo test --manifest-path windows/tauri/src-tauri/Cargo.toml -p lithe-common-encodings',
        'cargo test --manifest-path Plugins/win/Official/CommonEncodings/native/Cargo.toml')
replace('Plugins/win/Official/CommonEncodings/README.md',
        'cargo test --manifest-path windows/tauri/src-tauri/Cargo.toml -p lithe-project document_file',
        'cargo test --manifest-path windows/tauri/crates/project/Cargo.toml document_file')
replace('.agents/notes/implemented/feature/2026-09-24-document-encoding-switch.md',
        'cargo test --manifest-path windows/tauri/src-tauri/Cargo.toml -p lithe-project document_file',
        'cargo test --manifest-path windows/tauri/crates/project/Cargo.toml document_file')

workflow = Path('.github/workflows/ci-windows.yml')
text = workflow.read_text()
lines = text.splitlines(keepends=True)
index = next(i for i, line in enumerate(lines) if '--report .artifacts/test-stability/windows-documents.json' in line)
assert lines[index + 1].strip() == 'if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }'
lines[index + 2:index + 2] = [
    '          node .agents/skills/write-stable-tests/scripts/run-bun-tests-with-timing.mjs --suite-timeout-ms 120000 --report .artifacts/test-stability/windows-encodings.json -- src/extensions/document-encodings src/features/editor/services/document-encoding-workflow.test.ts src/features/file-system/controllers/read-file-with-feedback.test.ts\n',
    '          if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }\n',
]
workflow.write_text(''.join(lines))
