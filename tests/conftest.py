"""Shared fixtures and markers for tests."""

import sys

import pytest

macos_only = pytest.mark.skipif(sys.platform != "darwin", reason="macOS only")
slow = pytest.mark.slow
