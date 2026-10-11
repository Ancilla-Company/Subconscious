"""Selenium screenshot smoke check for an already-running Flutter web client.

Run after launching `flutter run -d chrome` with the connected engine defines:
    $env:SUBCONSCIOUS_WEB_URL='http://localhost:PORT'
    python -m pytest e2e -q
"""

from __future__ import annotations

import os
from pathlib import Path

import pytest
from selenium import webdriver
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.support.ui import WebDriverWait


@pytest.fixture()
def driver():
    url = os.getenv("SUBCONSCIOUS_WEB_URL")
    if not url:
        pytest.skip("Set SUBCONSCIOUS_WEB_URL to the running Flutter web client.")
    options = Options()
    if os.getenv("SUBCONSCIOUS_E2E_HEADLESS", "true").casefold() == "true":
        options.add_argument("--headless=new")
    options.add_argument("--window-size=1440,900")
    browser = webdriver.Chrome(options=options)
    browser.get(url)
    try:
        yield browser
    finally:
        browser.quit()


def test_web_shell_renders_and_captures_screenshot(driver: webdriver.Chrome, tmp_path: Path) -> None:
    WebDriverWait(driver, 20).until(lambda page: page.execute_script("return document.readyState") == "complete")
    WebDriverWait(driver, 20).until(lambda page: page.title == "Subconscious")
    screenshot = tmp_path / "subconscious-web-shell.png"
    assert driver.save_screenshot(str(screenshot))
    assert screenshot.stat().st_size > 0
