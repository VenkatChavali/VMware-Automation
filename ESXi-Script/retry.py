# -*- coding: utf-8 -*-
"""
retry.py
Universal retry logic used across all modules.

Why this exists as a separate module:
  The original PS script had ad-hoc retry patterns scattered everywhere:
    - Start-Sleep -Seconds 60; try { ... } catch {}
    - if($fwVerInv -notlike "*error*") {} else { Start-Sleep -Seconds 60; try { ... } }

  Centralising retry logic here means:
    - Consistent backoff across every external call
    - One place to tune retry counts / waits for your environment
    - Retry behaviour is visible and testable independently

Usage:
    from retry import retry, RetryExhausted

    # As a decorator
    @retry(attempts=3, delay=30, label="iDRAC inventory")
    def get_inventory():
        return rf.get_firmware_inventory()

    # As a context (inline)
    result = retry_call(
        fn      = lambda: rf.upload_and_stage_firmware(binary),
        attempts = 2,
        delay    = 60,
        label    = f"upload {binary.name}",
        logger   = self.logger,
    )
"""

import functools
import time
from typing import Any, Callable, Type


class RetryExhausted(Exception):
    """Raised when all retry attempts are exhausted."""
    pass


def retry(
    attempts: int = 3,
    delay: float  = 30,
    backoff: float = 1.5,
    exceptions: tuple[Type[Exception], ...] = (Exception,),
    label: str = "",
    logger=None,
):
    """
    Decorator that retries a function on failure.

    Args:
        attempts : max number of attempts (including the first)
        delay    : initial wait between attempts in seconds
        backoff  : multiply delay by this after each failure (1.0 = no backoff)
        exceptions: only retry on these exception types
        label    : human-readable name for log messages
        logger   : HostLogger instance (optional -- prints to stdout if None)

    Example:
        @retry(attempts=3, delay=60, label="vCenter connect")
        def connect():
            return SmartConnect(host=vcenter, ...)
    """
    def decorator(fn: Callable) -> Callable:
        @functools.wraps(fn)
        def wrapper(*args, **kwargs) -> Any:
            return retry_call(
                fn        = lambda: fn(*args, **kwargs),
                attempts  = attempts,
                delay     = delay,
                backoff   = backoff,
                exceptions= exceptions,
                label     = label or fn.__name__,
                logger    = logger,
            )
        return wrapper
    return decorator


def retry_call(
    fn: Callable,
    attempts: int  = 3,
    delay: float   = 30,
    backoff: float = 1.5,
    exceptions: tuple[Type[Exception], ...] = (Exception,),
    label: str     = "operation",
    logger         = None,
    fatal_check: Callable[[Exception], bool] | None = None,
) -> Any:
    """
    Call fn() with retry logic. Returns result on success.
    Raises RetryExhausted if all attempts fail.

    Args:
        fn           : zero-argument callable to retry
        attempts     : max total attempts
        delay        : initial sleep between retries (seconds)
        backoff      : delay multiplier per failure (1.5 = exponential backoff)
        exceptions   : exception types to catch and retry
        label        : name for log messages
        logger       : HostLogger (optional)
        fatal_check  : callable(exc) -> True if this exception should NOT be retried
                       e.g. lambda exc: "not applicable" in str(exc)
    """
    _log  = _make_log(logger)
    wait  = delay
    last_exc: Exception | None = None

    for attempt in range(1, attempts + 1):
        try:
            return fn()

        except exceptions as exc:
            last_exc = exc

            # Fatal exceptions -- don't retry, raise immediately
            if fatal_check and fatal_check(exc):
                _log(f"[{label}] Fatal error (no retry): {exc}")
                raise

            if attempt < attempts:
                _log(
                    f"[{label}] Attempt {attempt}/{attempts} failed: {exc}. "
                    f"Retrying in {wait:.0f}s ..."
                )
                time.sleep(wait)
                wait *= backoff
            else:
                _log(
                    f"[{label}] All {attempts} attempts failed. Last error: {exc}"
                )

    raise RetryExhausted(
        f"{label} failed after {attempts} attempts. Last error: {last_exc}"
    ) from last_exc


def _make_log(logger) -> Callable[[str], None]:
    """Return a log function -- uses logger.warning if available, else print."""
    if logger and hasattr(logger, "warning"):
        return logger.warning
    return print
