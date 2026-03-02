"""Teams mute detection via macOS Accessibility API.

Polls the Teams UI for the mute/unmute button state and records
transitions as a timeline that can be used to mask mic audio.
"""

import logging
import threading
import time
from dataclasses import dataclass

log = logging.getLogger(__name__)

# Button labels across locales (lowercase for comparison)
_MUTE_LABELS = {"mute", "unmute", "stummschalten", "stummschaltung aufheben"}


@dataclass
class MuteTransition:
    """A point in time where the mute state changed."""

    timestamp: float  # time.monotonic() value
    is_muted: bool


def _load_ax_functions():
    """Load Accessibility API functions from HIServices via pyobjc.

    Returns (AXIsProcessTrusted, AXUIElementCreateApplication,
             AXUIElementCopyAttributeValue) or raises ImportError.
    """
    import objc
    from Foundation import NSBundle

    bundle = NSBundle.bundleWithPath_(
        "/System/Library/Frameworks/ApplicationServices.framework"
        "/Frameworks/HIServices.framework"
    )
    if not bundle:
        raise ImportError("HIServices framework not found")

    functions = [
        ("AXIsProcessTrusted", b"B"),
        ("AXUIElementCreateApplication", b"@i"),
    ]
    d = {}
    objc.loadBundleFunctions(bundle, d, functions)
    return d["AXIsProcessTrusted"], d["AXUIElementCreateApplication"]


def _is_accessibility_trusted() -> bool:
    """Check whether this process has Accessibility permission."""
    try:
        ax_trusted, _ = _load_ax_functions()
        return bool(ax_trusted())
    except Exception:
        return False


def _find_mute_button(element, depth: int = 0, max_depth: int = 10):
    """Recursively search AX tree for a button matching mute labels.

    Returns the element if found, None otherwise.
    """
    if depth > max_depth:
        return None

    import CoreFoundation

    try:
        err, role = CoreFoundation.AXUIElementCopyAttributeValue(
            element, "AXRole", None
        )
        if err != 0:
            return None

        if role == "AXButton":
            err, title = CoreFoundation.AXUIElementCopyAttributeValue(
                element, "AXTitle", None
            )
            if err == 0 and title and str(title).lower() in _MUTE_LABELS:
                return element

            # Also check AXDescription (some buttons use description instead)
            err, desc = CoreFoundation.AXUIElementCopyAttributeValue(
                element, "AXDescription", None
            )
            if err == 0 and desc and str(desc).lower() in _MUTE_LABELS:
                return element

        # Recurse into children
        err, children = CoreFoundation.AXUIElementCopyAttributeValue(
            element, "AXChildren", None
        )
        if err != 0 or not children:
            return None

        for child in children:
            result = _find_mute_button(child, depth + 1, max_depth)
            if result is not None:
                return result

    except Exception:
        return None

    return None


def _read_mute_state(pid: int) -> bool | None:
    """Read the mute state from Teams UI for the given PID.

    Returns True if muted, False if unmuted, None if can't determine.
    """
    try:
        import CoreFoundation

        _, ax_create_app = _load_ax_functions()
        app_element = ax_create_app(pid)
        if not app_element:
            return None

        button = _find_mute_button(app_element)
        if button is None:
            return None

        # Check the button title — "Unmute" means currently muted
        err, title = CoreFoundation.AXUIElementCopyAttributeValue(
            button, "AXTitle", None
        )
        if err != 0 or not title:
            # Try description
            err, title = CoreFoundation.AXUIElementCopyAttributeValue(
                button, "AXDescription", None
            )
            if err != 0 or not title:
                return None

        title_lower = str(title).lower()
        if title_lower in {"unmute", "stummschaltung aufheben"}:
            return True  # muted (button says "Unmute")
        if title_lower in {"mute", "stummschalten"}:
            return False  # unmuted (button says "Mute")
        return None

    except Exception as exc:
        log.debug("Failed to read mute state: %s", exc)
        return None


class MuteTracker:
    """Polls Teams mute state and records transitions.

    Runs a daemon thread that checks mute state every ``poll_interval``
    seconds. The timeline is available via :attr:`timeline`.

    Graceful degradation: if Accessibility API is unavailable or
    permission is denied, logs a warning and records an empty timeline.
    """

    def __init__(self, teams_pid: int, poll_interval: float = 0.5):
        self.teams_pid = teams_pid
        self.poll_interval = poll_interval
        self.timeline: list[MuteTransition] = []
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._last_state: bool | None = None

    def start(self) -> None:
        """Start polling in a daemon thread."""
        if not _is_accessibility_trusted():
            log.warning(
                "Accessibility permission not granted — mute detection disabled. "
                "Enable: System Settings > Privacy & Security > Accessibility"
            )
            return

        self._thread = threading.Thread(target=self._poll_loop, daemon=True)
        self._thread.start()
        log.info("Mute tracker started for PID %d", self.teams_pid)

    def stop(self) -> None:
        """Stop the polling thread."""
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=2)
            self._thread = None
        log.info("Mute tracker stopped — %d transitions recorded", len(self.timeline))

    def _poll_loop(self) -> None:
        """Poll mute state until stopped."""
        while not self._stop.is_set():
            state = _read_mute_state(self.teams_pid)
            if state is not None and state != self._last_state:
                transition = MuteTransition(timestamp=time.monotonic(), is_muted=state)
                self.timeline.append(transition)
                self._last_state = state
                log.debug("Mute transition: %s", "MUTED" if state else "UNMUTED")
            self._stop.wait(self.poll_interval)
