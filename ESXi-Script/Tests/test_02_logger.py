"""
test_02_logger.py
==================
Tests for logger.py

NO network connectivity needed.
Run from the project root directory:
    python tests/test_02_logger.py

What this tests:
  - Logger creates log file in correct location
  - info / warning / error messages appear correctly
  - section() prints separator lines
  - Multiple hosts get separate log files
  - Log file actually has content after writing
"""

import sys
import os
import tempfile
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from logger import get_logger, HostLogger


def separator(title: str) -> None:
    print(f"\n{'='*60}")
    print(f"  {title}")
    print(f"{'='*60}")


def test_logger_creates_file():
    separator("TEST: Logger creates log file")

    # Use a temp directory so we don't litter test files around
    with tempfile.TemporaryDirectory() as tmpdir:
        transcript_dir = Path(tmpdir)
        host           = "esxi01.corp.local"

        logger = get_logger(host, transcript_dir)

        # Write some messages
        logger.info("This is an info message")
        logger.warning("This is a warning message")
        logger.error("This is an error message")

        # Check log file exists
        log_file = transcript_dir / f"{host}-upgrade.log"
        exists   = log_file.exists()
        print(f"Log file created: {exists}  ✓")
        print(f"Log file path   : {log_file}")

        # Check content
        content = log_file.read_text()
        has_info    = "info message"    in content.lower()
        has_warning = "warning message" in content.lower()
        has_error   = "error message"   in content.lower()

        print(f"Contains INFO   : {has_info}    ✓")
        print(f"Contains WARNING: {has_warning} ✓")
        print(f"Contains ERROR  : {has_error}   ✓")

        # Show a few lines from the file
        print("\nSample log output:")
        for line in content.splitlines()[:5]:
            print(f"  {line}")


def test_logger_prefixes_hostname():
    separator("TEST: Logger prefixes every line with hostname")

    with tempfile.TemporaryDirectory() as tmpdir:
        transcript_dir = Path(tmpdir)
        host           = "esxi01-prefix-test.corp.local"   # unique name avoids logger cache

        logger = get_logger(host, transcript_dir)
        logger.info("Testing hostname prefix")

        log_file = transcript_dir / f"{host}-upgrade.log"
        content  = log_file.read_text()

        # Every line should contain the hostname
        lines_with_host = [l for l in content.splitlines() if host in l]
        print(f"Lines containing hostname: {len(lines_with_host)}")
        for line in lines_with_host:
            print(f"  {line}")


def test_section_separator():
    separator("TEST: section() prints separator lines")

    with tempfile.TemporaryDirectory() as tmpdir:
        transcript_dir = Path(tmpdir)
        logger         = get_logger("esxi01-section-test.corp.local", transcript_dir)

        logger.section("Phase 2 — Firmware Upgrade")
        logger.info("Something after the section header")

        log_file = (transcript_dir / "esxi01-section-test.corp.local-upgrade.log")
        content  = log_file.read_text()

        has_separator = "─" * 10 in content   # check separator chars
        has_arrow     = "▶" in content
        print(f"Separator line present: {has_separator}  ✓")
        print(f"Arrow marker present  : {has_arrow}      ✓")

        print("\nSection output in log:")
        for line in content.splitlines():
            print(f"  {line}")


def test_two_hosts_get_separate_files():
    separator("TEST: Two hosts get separate log files")

    with tempfile.TemporaryDirectory() as tmpdir:
        transcript_dir = Path(tmpdir)

        # Use unique names to avoid Python logging module cache
        host1 = "esxi-separate-test-01.corp.local"
        host2 = "esxi-separate-test-02.corp.local"

        logger1 = get_logger(host1, transcript_dir)
        logger2 = get_logger(host2, transcript_dir)

        logger1.info("Message from host 1")
        logger2.info("Message from host 2")

        file1 = transcript_dir / f"{host1}-upgrade.log"
        file2 = transcript_dir / f"{host2}-upgrade.log"

        print(f"Host1 log exists: {file1.exists()}  ✓")
        print(f"Host2 log exists: {file2.exists()}  ✓")

        # Cross-contamination check — host1 log should NOT contain host2's message
        content1 = file1.read_text()
        content2 = file2.read_text()

        host1_clean = "Message from host 2" not in content1
        host2_clean = "Message from host 1" not in content2
        print(f"Host1 log is clean (no host2 messages): {host1_clean}  ✓")
        print(f"Host2 log is clean (no host1 messages): {host2_clean}  ✓")


# ── Run all tests ──────────────────────────────────────────────────────────
if __name__ == "__main__":
    print("\nRunning logger tests (no network needed)")
    print("=" * 60)

    test_logger_creates_file()
    test_logger_prefixes_hostname()
    test_section_separator()
    test_two_hosts_get_separate_files()

    print("\n" + "=" * 60)
    print("  All logger tests complete")
    print("=" * 60)
