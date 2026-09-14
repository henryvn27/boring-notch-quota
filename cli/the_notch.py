#!/usr/bin/env python3
"""Read-only Codex quota and pacing CLI for The Notch.

The CLI intentionally makes recommendations only. It never changes a model,
starts work, consumes a reset, or edits Codex configuration.
"""

from __future__ import annotations

import argparse
import json
import os
import select
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


APP_SUPPORT = Path.home() / "Library" / "Application Support" / "The Notch"
HISTORY_PATH = APP_SUPPORT / "usage-history.jsonl"
DEFAULT_TIMEOUT = 8.0


class UsageError(RuntimeError):
    pass


@dataclass(frozen=True)
class Window:
    id: str
    name: str
    role: str
    used_percent: float
    duration_minutes: int | None
    resets_at: float | None

    @property
    def remaining_percent(self) -> float:
        return max(0.0, min(100.0, 100.0 - self.used_percent))


def iso(timestamp: float | None) -> str | None:
    if timestamp is None:
        return None
    return datetime.fromtimestamp(timestamp, tz=timezone.utc).isoformat().replace("+00:00", "Z")


def locate_codex() -> str:
    candidates: list[str] = []
    explicit = os.environ.get("THE_NOTCH_CODEX_PATH")
    if explicit:
        candidates.append(explicit)
    candidates.extend(
        [
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            str(Path.home() / ".local/bin/codex"),
        ]
    )
    found = shutil.which("codex")
    if found:
        candidates.append(found)
    for candidate in candidates:
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    raise UsageError("Codex is not installed or could not be located.")


def rpc_message(method: str, request_id: int | None = None, params: dict[str, Any] | None = None) -> str:
    message: dict[str, Any] = {"method": method}
    if request_id is not None:
        message["id"] = request_id
    if params is not None:
        message["params"] = params
    return json.dumps(message, separators=(",", ":")) + "\n"


def fetch_usage(timeout: float = DEFAULT_TIMEOUT) -> tuple[list[Window], str | None]:
    executable = locate_codex()
    try:
        process = subprocess.Popen(
            [executable, "app-server"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            bufsize=1,
        )
    except OSError as error:
        raise UsageError(f"Could not start Codex app-server: {error}") from error

    try:
        assert process.stdin and process.stdout
        process.stdin.write(
            rpc_message(
                "initialize",
                request_id=0,
                params={
                    "clientInfo": {
                        "name": "the-notch-cli",
                        "title": "The Notch CLI",
                        "version": "0.1.0",
                    }
                },
            )
        )
        process.stdin.write(rpc_message("initialized", params={}))
        process.stdin.write(rpc_message("account/rateLimits/read", request_id=2, params={}))
        process.stdin.flush()

        deadline = time.monotonic() + timeout
        result: dict[str, Any] | None = None
        while time.monotonic() < deadline:
            remaining = max(0.05, deadline - time.monotonic())
            ready, _, _ = select.select([process.stdout], [], [], remaining)
            if not ready:
                break
            line = process.stdout.readline()
            if not line:
                break
            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                continue
            if message.get("id") == 2:
                if message.get("error"):
                    raise UsageError(message["error"].get("message", "Codex returned an error."))
                result = message.get("result")
                break
        if result is None:
            raise UsageError("Codex did not return rate limits before the timeout.")
        return parse_usage_result(result)
    finally:
        if process.stdin:
            process.stdin.close()
        if process.stdout:
            process.stdout.close()
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                process.kill()


def parse_usage_result(result: dict[str, Any]) -> tuple[list[Window], str | None]:
    keyed = result.get("rateLimitsByLimitId") or {}
    account = result.get("rateLimits")
    if not account or not (account.get("primary") or account.get("secondary")):
        account = keyed.get("codex")
    if not account and len(keyed) == 1:
        account = next(iter(keyed.values()))
    if not account:
        raise UsageError("Codex returned no account-level rate-limit windows.")

    bucket_id = account.get("limitId") or "codex"
    bucket_name = account.get("limitName") or "Codex"
    windows: list[Window] = []
    for role in ("primary", "secondary"):
        raw = account.get(role)
        if not raw:
            continue
        duration = raw.get("windowDurationMins")
        name = display_name(duration, role)
        if len([x for x in (account.get("primary"), account.get("secondary")) if x]) > 1:
            name = f"{name} · {bucket_name}"
        windows.append(
            Window(
                id=f"{bucket_id}.{role}",
                name=name,
                role=role,
                used_percent=max(0.0, min(100.0, float(raw.get("usedPercent", 0)))),
                duration_minutes=int(duration) if duration is not None else None,
                resets_at=float(raw["resetsAt"]) if raw.get("resetsAt") is not None else None,
            )
        )
    if not windows:
        raise UsageError("Codex returned empty rate-limit windows.")
    return windows, account.get("planType")


def display_name(minutes: int | None, role: str) -> str:
    if minutes == 300:
        return "5-hour window"
    if minutes == 10_080:
        return "Weekly window"
    if minutes and minutes % 1_440 == 0:
        return f"{minutes // 1_440}-day window"
    if minutes and minutes % 60 == 0:
        return f"{minutes // 60}-hour window"
    if minutes:
        return f"{minutes}-minute window"
    return "Primary window" if role == "primary" else "Secondary window"


def read_history() -> list[dict[str, Any]]:
    if not HISTORY_PATH.exists():
        return []
    entries: list[dict[str, Any]] = []
    try:
        for line in HISTORY_PATH.read_text().splitlines()[-240:]:
            try:
                entry = json.loads(line)
                if isinstance(entry, dict):
                    entries.append(entry)
            except json.JSONDecodeError:
                continue
    except OSError:
        return []
    return entries


def record_history(windows: list[Window], observed_at: float) -> None:
    APP_SUPPORT.mkdir(parents=True, exist_ok=True)
    with HISTORY_PATH.open("a", encoding="utf-8") as handle:
        handle.write(
            json.dumps(
                {
                    "observedAt": observed_at,
                    "windows": [
                        {"id": window.id, "usedPercent": window.used_percent}
                        for window in windows
                    ],
                },
                separators=(",", ":"),
            )
            + "\n"
        )


def slope_for(window: Window, history: list[dict[str, Any]], now: float) -> float | None:
    observations: list[tuple[float, float]] = []
    for entry in history:
        timestamp = entry.get("observedAt")
        for item in entry.get("windows", []):
            if item.get("id") == window.id and isinstance(timestamp, (int, float)):
                observations.append((float(timestamp), float(item.get("usedPercent", 0))))
    observations.append((now, window.used_percent))
    observations = [(t, value) for t, value in observations if now - t <= 3 * 3600 and t <= now]
    if len(observations) < 2:
        return None
    oldest = min(observations, key=lambda item: item[0])
    newest = max(observations, key=lambda item: item[0])
    elapsed = newest[0] - oldest[0]
    return None if elapsed < 60 else (newest[1] - oldest[1]) / (elapsed / 3600)


def window_payload(window: Window, history: list[dict[str, Any]], now: float) -> dict[str, Any]:
    slope = slope_for(window, history, now)
    expected: float | None = None
    if window.duration_minutes and window.resets_at:
        start = window.resets_at - window.duration_minutes * 60
        expected = max(0.0, min(100.0, (now - start) / (window.duration_minutes * 60) * 100))
    pace_delta = window.used_percent - expected if expected is not None else None
    projected = None
    if window.resets_at and slope is not None:
        projected = window.used_percent + slope * max(0.0, window.resets_at - now) / 3600
    status = "unknown"
    if pace_delta is not None:
        status = "ahead_of_pace" if pace_delta > 2 else "behind_pace" if pace_delta < -2 else "on_pace"
    return {
        "id": window.id,
        "name": window.name,
        "role": window.role,
        "usedPercent": round(window.used_percent, 3),
        "remainingPercent": round(window.remaining_percent, 3),
        "durationMinutes": window.duration_minutes,
        "resetsAt": iso(window.resets_at),
        "expectedPercent": round(expected, 3) if expected is not None else None,
        "paceDeltaPercent": round(pace_delta, 3) if pace_delta is not None else None,
        "changePercentPerHour": round(slope, 4) if slope is not None else None,
        "projectedUsageAtResetPercent": round(projected, 3) if projected is not None else None,
        "status": status,
        "confidence": "high" if slope is not None and len(history) >= 2 else "low",
    }


def status_payload(windows: list[Window], plan_type: str | None, record: bool) -> dict[str, Any]:
    now = time.time()
    history = read_history()
    if record:
        record_history(windows, now)
        history = read_history()
    return {
        "product": "The Notch",
        "source": "Codex app-server",
        "observedAt": iso(now),
        "planType": plan_type,
        "windows": [window_payload(window, history, now) for window in windows],
        "resets": {
            "bankedCount": None,
            "bankedStatus": "unknown",
            "note": "Codex did not report banked reset data.",
        },
        "historyRecorded": record,
    }


def recommendation(payload: dict[str, Any]) -> dict[str, Any]:
    windows = payload["windows"]
    worst = max(
        windows,
        key=lambda item: item["paceDeltaPercent"] if item["paceDeltaPercent"] is not None else -10_000,
    )
    delta = worst["paceDeltaPercent"]
    projected = worst["projectedUsageAtResetPercent"]
    if (projected is not None and projected >= 100) or (delta is not None and delta >= 10):
        recommendation_name = "conservative"
        concurrency = 1
        reason = "Projected usage reaches the limit or is substantially ahead of pace."
    elif delta is not None and delta >= 5:
        recommendation_name = "balanced"
        concurrency = 2
        reason = "Usage is ahead of pace, but the window is still recoverable."
    else:
        recommendation_name = "normal"
        concurrency = None
        reason = "No material pacing risk is visible from the available data."
    return {
        "mode": recommendation_name,
        "recommendedConcurrency": concurrency,
        "recommendedModelClass": "balanced" if recommendation_name != "normal" else "user_selected",
        "reason": reason,
        "window": worst["name"],
        "automaticActionTaken": False,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="the-notch", description="Read-only Codex quota and pacing data.")
    subparsers = parser.add_subparsers(dest="command", required=True)
    for name in ("status", "pace", "resets", "recommend"):
        sub = subparsers.add_parser(name)
        sub.add_argument("--json", action="store_true", help="emit machine-readable JSON")
        sub.add_argument("--record", action="store_true", help="record this observation for rate-of-change estimates")
    args = parser.parse_args(argv)
    try:
        windows, plan_type = fetch_usage()
        payload = status_payload(windows, plan_type, args.record)
    except UsageError as error:
        print(f"the-notch: {error}", file=sys.stderr)
        return 2

    if args.command == "recommend":
        output: Any = {**payload, "recommendation": recommendation(payload)}
    elif args.command == "resets":
        output = {"product": payload["product"], "observedAt": payload["observedAt"], "resets": payload["resets"], "windows": payload["windows"]}
    else:
        output = payload

    if args.json:
        print(json.dumps(output, indent=2, sort_keys=True))
    else:
        for window in output.get("windows", []):
            delta = window.get("paceDeltaPercent")
            delta_text = "unknown pace" if delta is None else f"{delta:+.1f} pts vs pace"
            print(f"{window['name']}: {window['usedPercent']:.1f}% used · {delta_text} · resets {window['resetsAt'] or 'unknown'}")
        if "recommendation" in output:
            print(f"Recommendation: {output['recommendation']['mode']} ({output['recommendation']['reason']})")
        if output.get("resets", {}).get("bankedStatus") == "unknown":
            print("Banked resets: unavailable from Codex")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
