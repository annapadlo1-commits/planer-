from __future__ import annotations

from collections import defaultdict
from collections.abc import Iterable
from dataclasses import dataclass
from datetime import datetime, time, timedelta
from zoneinfo import ZoneInfo

from .models import (
    AvailabilityWindow,
    Employee,
    ExternalAssignment,
    HardBlock,
    Snapshot,
    WorkPattern,
)
from .slots import Slot


@dataclass(frozen=True)
class Eligibility:
    allowed: bool
    reasons: tuple[str, ...] = ()


def intervals_overlap(
    first_start: datetime,
    first_end: datetime,
    second_start: datetime,
    second_end: datetime,
) -> bool:
    return (
        first_start.timestamp() < second_end.timestamp()
        and second_start.timestamp() < first_end.timestamp()
    )


def violates_rest(
    first_start: datetime,
    first_end: datetime,
    second_start: datetime,
    second_end: datetime,
    rest_minutes: int,
) -> bool:
    rest_seconds = rest_minutes * 60
    if first_start.timestamp() <= second_start.timestamp():
        return second_start.timestamp() < first_end.timestamp() + rest_seconds
    return first_start.timestamp() < second_end.timestamp() + rest_seconds


class EligibilityIndex:
    def __init__(self, snapshot: Snapshot):
        self.snapshot = snapshot
        self.timezone = ZoneInfo(snapshot.settings.timezone)
        self.windows: dict[str, list[AvailabilityWindow]] = defaultdict(list)
        self.blocks: dict[str, list[HardBlock]] = defaultdict(list)
        self.patterns: dict[str, list[WorkPattern]] = defaultdict(list)
        self.external: dict[str, list[ExternalAssignment]] = defaultdict(list)
        for window in snapshot.availability_windows:
            self.windows[window.employee_id].append(window)
        for block in snapshot.hard_blocks:
            self.blocks[block.employee_id].append(block)
        for pattern in snapshot.work_patterns:
            self.patterns[pattern.employee_id].append(pattern)
        for assignment in snapshot.external_assignments:
            self.external[assignment.employee_id].append(assignment)
        for collection in (self.windows, self.external):
            for values in collection.values():
                values.sort(key=lambda item: item.start)

    def minimum_rest(self, employee: Employee) -> int:
        return (
            employee.minimum_rest_minutes
            if employee.minimum_rest_minutes is not None
            else self.snapshot.settings.default_minimum_rest_minutes
        )

    def availability_for_slot(
        self, employee_id: str, slot: Slot
    ) -> tuple[AvailabilityWindow, ...]:
        slot_timezone = slot.start.tzinfo or self.timezone
        day_start = datetime.combine(slot.date, time.min, slot_timezone)
        day_end = day_start + timedelta(days=1)
        return tuple(
            window
            for window in self.windows.get(employee_id, ())
            if intervals_overlap(window.start, window.end, day_start, day_end)
        )

    def evaluate(self, employee: Employee, slot: Slot) -> Eligibility:
        reasons: list[str] = []
        if not employee.role_allowed_on(slot.role_id, slot.date):
            reasons.append("ROLE")
        if not employee.duties_allowed_on(
            slot.duty_ids, slot.role_id, slot.location_id, slot.date
        ):
            reasons.append("DUTIES")
        if not employee.location_allowed_on(slot.location_id, slot.date):
            reasons.append("LOCATION")
        if slot.shift_template_id in employee.blocked_shift_template_ids:
            reasons.append("SHIFT_PERIOD_BLOCKED")

        slot_timezone = slot.start.tzinfo or self.timezone
        local_start = slot.start.astimezone(slot_timezone)
        local_end = slot.end.astimezone(slot_timezone)
        if employee.employment_start and local_start.date() < employee.employment_start:
            reasons.append("EMPLOYMENT_START")
        if employee.employment_end and local_end.date() > employee.employment_end:
            reasons.append("EMPLOYMENT_END")
        if employee.no_weekends and slot.date.isoweekday() in {6, 7}:
            reasons.append("WEEKEND")

        active_hard_patterns = tuple(
            pattern
            for pattern in self.patterns.get(employee.id, ())
            if pattern.enforcement == "HARD" and pattern.active_on(slot.date)
        )
        if active_hard_patterns and not any(
            self.pattern_matches_slot(pattern, slot)
            for pattern in active_hard_patterns
        ):
            reasons.append("PERMANENT_WORK_PATTERN")

        start_minute = local_start.hour * 60 + local_start.minute
        end_minute = local_end.hour * 60 + local_end.minute
        if local_end.date() > local_start.date():
            end_minute += 24 * 60
        if (
            employee.only_morning_before_minute is not None
            and end_minute > employee.only_morning_before_minute
        ):
            reasons.append("ONLY_MORNING")
        if (
            employee.only_evening_after_minute is not None
            and start_minute < employee.only_evening_after_minute
        ):
            reasons.append("ONLY_EVENING")

        windows = self.availability_for_slot(employee.id, slot)
        if windows:
            if not any(
                window.start.timestamp() <= slot.start.timestamp()
                and window.end.timestamp() >= slot.end.timestamp()
                for window in windows
            ):
                reasons.append("AVAILABILITY_WINDOW")
        elif not (
            employee.missing_availability_means_available
            if employee.missing_availability_means_available is not None
            else self.snapshot.settings.missing_availability_means_available
        ):
            reasons.append("MISSING_AVAILABILITY")

        for block in self.blocks.get(employee.id, ()):
            if block.start is not None and block.end is not None:
                if intervals_overlap(slot.start, slot.end, block.start, block.end):
                    reasons.append("HARD_BLOCK")
                    break
            elif block.date_start is not None and block.date_end is not None:
                block_start = datetime.combine(
                    block.date_start, time.min, slot_timezone
                )
                block_end = datetime.combine(
                    block.date_end + timedelta(days=1), time.min, slot_timezone
                )
                if intervals_overlap(slot.start, slot.end, block_start, block_end):
                    reasons.append("HARD_BLOCK")
                    break

        rest_minutes = self.minimum_rest(employee)
        for assignment in self.external.get(employee.id, ()):
            if violates_rest(
                slot.start,
                slot.end,
                assignment.start,
                assignment.end,
                rest_minutes,
            ):
                reasons.append("EXTERNAL_ASSIGNMENT_CONFLICT_OR_REST")
                break
        return Eligibility(allowed=not reasons, reasons=tuple(sorted(set(reasons))))

    def pattern_matches_slot(self, pattern: WorkPattern, slot: Slot) -> bool:
        if slot.date.isoweekday() != pattern.weekday:
            return False
        if pattern.role_id is not None and pattern.role_id != slot.role_id:
            return False
        if pattern.location_id is not None and pattern.location_id != slot.location_id:
            return False
        slot_timezone = slot.start.tzinfo or self.timezone
        local_start = slot.start.astimezone(slot_timezone)
        local_end = slot.end.astimezone(slot_timezone)
        slot_start_minute = local_start.hour * 60 + local_start.minute
        slot_end_minute = local_end.hour * 60 + local_end.minute
        if local_end.date() > local_start.date():
            slot_end_minute += 24 * 60
        pattern_start_minute = pattern.local_start.hour * 60 + pattern.local_start.minute
        pattern_end_minute = pattern.local_end.hour * 60 + pattern.local_end.minute
        if pattern_end_minute <= pattern_start_minute:
            pattern_end_minute += 24 * 60
        return (
            pattern_start_minute <= slot_start_minute
            and slot_end_minute <= pattern_end_minute
        )

    def violates_preferred_work_pattern(
        self, employee_id: str, slot: Slot
    ) -> bool:
        patterns = tuple(
            pattern
            for pattern in self.patterns.get(employee_id, ())
            if pattern.enforcement == "PREFERENCE" and pattern.active_on(slot.date)
        )
        return bool(patterns) and not any(
            self.pattern_matches_slot(pattern, slot) for pattern in patterns
        )

    def eligible_pairs(
        self, employees: Iterable[Employee], slots: Iterable[Slot]
    ) -> dict[tuple[str, str], Eligibility]:
        return {
            (employee.id, slot.id): self.evaluate(employee, slot)
            for employee in employees
            for slot in slots
        }
