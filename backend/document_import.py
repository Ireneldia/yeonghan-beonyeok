"""외부 프로그램 없이 PDF를 검증하고 지정된 저장 경로로 복사한다."""
import os
import shutil
import tempfile
from pathlib import Path

import fitz

SUPPORTED_EXTENSIONS = (".pdf",)


def formats() -> dict:
    return {"extensions": list(SUPPORTED_EXTENSIONS)}


def _validate_pdf(path: Path) -> int:
    try:
        with fitz.open(path) as document:
            if document.needs_pass:
                raise ValueError("암호로 보호된 PDF는 암호를 해제한 뒤 가져오세요")
            if not document.is_pdf or not len(document):
                raise ValueError("올바른 PDF 문서가 아닙니다")
            return len(document)
    except (fitz.FileDataError, fitz.EmptyFileError, OSError) as error:
        raise ValueError("PDF 파일을 읽을 수 없습니다") from error


def copy_pdf(source: Path, destination: Path) -> int:
    source, destination = Path(source), Path(destination)
    if source.suffix.lower() not in SUPPORTED_EXTENSIONS:
        raise ValueError("PDF 문서만 가져올 수 있습니다")
    if not source.is_file() or not source.stat().st_size:
        raise ValueError("빈 문서 또는 읽을 수 없는 파일입니다")
    if source.resolve() == destination.resolve():
        return _validate_pdf(source)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".document-import-", dir=destination.parent) as directory:
        output = Path(directory) / "document.pdf"
        shutil.copyfile(source, output)
        pages = _validate_pdf(output)
        os.replace(output, destination)
        return pages
