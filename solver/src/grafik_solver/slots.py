from __future__ import annotations

from collections.abc import Mapping, Sequence
from dataclasses import dataclass, replace
from datetime import date, datetime, timedelta
from typing import Any
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from .models import Demand, ShiftTemplate, Snapshot, SnapshotError


@dataclass(frozen=True)
class Slot:
    id: str
    demand_id: str
    occurrence_id: str
    seat_index: int
    date: date
    shift_template_id: str
    location_id: str
    role_id: str
    duty_ids: tuple[str, ...]
    start: datetime
    end: datetime
    sequence_order: int | None = None

    @property
    def duration_minutes(self) -> int:
        return int((self.end.timestamp() - self.start.timestamp()) // 60)


def _days(start: date, end: date):
    current = start
    while current <= end:
        yield current
        current += timedelta(days=1)


def shift_sequence_boundaries(
    snapshot: Snapshot,
) -> dict[tuple[str, int], tuple[str, str]]:
    """Return the first/last template for every location and ISO weekday."""
    grouped: dict[tuple[str, int], list[ShiftTemplate]] = {}
    for template in snapshot.shift_templates:
        for weekday in template.weekdays:
            grouped.setdefault((template.location_id, weekday), []).append(template)

    boundaries: dict[tuple[str, int], tuple[str, str]] = {}
    for key, templates in grouped.items():
        # A single recurring shift is not a last->first hand-off pair.  Without
        # this guard the sequence rule would incorrectly force every second
        # day off in locations that operate one shift only.
        if len(templates) < 2:
            continue
        ordered = sorted(
            templates,
            key=lambda template: (
                template.sequence_order
                if template.sequence_order is not None
                else template.start_time.hour * 60 + template.start_time.minute,
                template.start_time.hour * 60 + template.start_time.minute,
                template.id,
            ),
        )
        boundaries[key] = (ordered[0].id, ordered[-1].id)
    return boundaries


def consecutive_shift_sequence(
    boundaries: Mapping[tuple[str, int], tuple[str, str]],
    first: Slot,
    second: Slot,
) -> bool:
    """Whether ``second`` is the next business shift after ``first``.

    Same-day sequences are handled by the stricter one-primary-shift-per-day
    invariant.  Here we close the cyclic boundary: the last configured shift
    of one day cannot be followed by the first configured shift of the next.
    """
    if second.date != first.date + timedelta(days=1):
        return False
    first_boundary = boundaries.get((first.location_id, first.date.isoweekday()))
    second_boundary = boundaries.get((second.location_id, second.date.isoweekday()))
    return bool(
        first_boundary
        and second_boundary
        and first.shift_template_id == first_boundary[1]
        and second.shift_template_id == second_boundary[0]
    )


def _demand_dates(
    snapshot: Snapshot, demand: Demand, template: ShiftTemplate
) -> list[date]:
    if demand.dates:
        dates = list(demand.dates)
    else:
        first = max(snapshot.period_start, demand.date_start or snapshot.period_start)
        last = min(snapshot.period_end, demand.date_end or snapshot.period_end)
        dates = list(_days(first, last)) if first <= last else []
    return [
        day
        for day in dates
        if snapshot.period_start <= day <= snapshot.period_end
        and day.isoweekday() in template.weekdays
    ]


def generate_slots(snapshot: Snapshot) -> tuple[Slot, ...]:
    try:
        ZoneInfo(snapshot.settings.timezone)
    except ZoneInfoNotFoundError as exc:
        raise SnapshotError(
            f"Unknown IANA timezone: {snapshot.settings.timezone}"
        ) from exc

    templates = {template.id: template for template in snapshot.shift_templates}
    location_timezones: dict[str, ZoneInfo] = {}
    for location in snapshot.locations:
        timezone_name = location.timezone or snapshot.settings.timezone
        try:
            location_timezones[location.id] = ZoneInfo(timezone_name)
        except ZoneInfoNotFoundError as exc:
            raise SnapshotError(
                f"Unknown IANA timezone for location {location.id}: {timezone_name}"
            ) from exc
    if len(templates) != len(snapshot.shift_templates):
        raise SnapshotError("Shift template identifiers must be unique")

    slots: list[Slot] = []
    identifiers: set[str] = set()
    for demand in sorted(snapshot.demand, key=lambda item: item.id):
        template = templates.get(demand.shift_template_id)
        if template is None:
            raise SnapshotError(
                f"Demand {demand.id} references missing shift template "
                f"{demand.shift_template_id}"
            )
        timezone = location_timezones.get(template.location_id)
        if timezone is None:
            raise SnapshotError(
                f"Shift template {template.id} references missing location "
                f"{template.location_id}"
            )
        for day in sorted(_demand_dates(snapshot, demand, template)):
            start = datetime.combine(day, template.start_time, timezone)
            end = datetime.combine(day, template.end_time, timezone)
            if template.ends_next_day or end <= start:
                end += timedelta(days=1)
            occurrence_id = f"{day.isoformat()}|{template.id}"
            duties_key = ",".join(sorted(demand.duty_ids)) or "-"
            for seat_index in range(demand.required_count):
                slot_id = (
                    f"{day.isoformat()}|{template.id}|{demand.role_id}|"
                    f"{duties_key}|{demand.id}|{seat_index + 1}"
                )
                if slot_id in identifiers:
                    raise SnapshotError(
                        f"Duplicate generated slot identifier: {slot_id}"
                    )
                identifiers.add(slot_id)
                slots.append(
                    Slot(
                        id=slot_id,
                        demand_id=demand.id,
                        occurrence_id=occurrence_id,
                        seat_index=seat_index,
                        date=day,
                        shift_template_id=template.id,
                        location_id=template.location_id,
                        role_id=demand.role_id,
                        duty_ids=demand.duty_ids,
                        start=start,
                        end=end,
                        sequence_order=template.sequence_order,
                    )
                )
    provided = snapshot.raw.get("slots")
    if provided is not None:
        slots = _resolve_and_validate_slots(slots, provided)
    slots.sort(key=lambda item: (item.start, item.location_id, item.role_id, item.id))
    return tuple(slots)


def _parse_timestamp(value: Any, field_name: str) -> datetime:
    try:
        parsed = datetime.fromisoformat(str(value))
    except (TypeError, ValueError) as exc:
        raise SnapshotError(
            f"Resolved slot {field_name} must be an ISO timestamp"
        ) from exc
    if parsed.tzinfo is None:
        raise SnapshotError(f"Resolved slot {field_name} must include a UTC offset")
    return parsed


def _resolve_and_validate_slots(generated: list[Slot], provided: Any) -> list[Slot]:
    if not isinstance(provided, Sequence) or isinstance(
        provided, (str, bytes, bytearray)
    ):
        raise SnapshotError("slots must be an array")
    provided_by_id: dict[str, Mapping[str, Any]] = {}
    for raw in provided:
        if not isinstance(raw, Mapping):
            raise SnapshotError("Every resolved slot must be an object")
        slot_id = str(raw.get("slotId", raw.get("slot_id", "")))
        if not slot_id or slot_id in provided_by_id:
            raise SnapshotError("Resolved slot identifiers must be present and unique")
        provided_by_id[slot_id] = raw
    if set(provided_by_id) != {slot.id for slot in generated}:
        missing = sorted({slot.id for slot in generated} - set(provided_by_id))
        extra = sorted(set(provided_by_id) - {slot.id for slot in generated})
        raise SnapshotError(
            "Resolved slots differ from generated demand; "
            f"missing={missing}, extra={extra}"
        )
    resolved: list[Slot] = []
    for slot in generated:
        raw = provided_by_id[slot.id]
        start = _parse_timestamp(raw.get("start"), "start")
        end = _parse_timestamp(raw.get("end"), "end")
        if end.timestamp() <= start.timestamp():
            raise SnapshotError(f"Resolved slot {slot.id} must have positive duration")

        # PostgreSQL is the authoritative local-time resolver. In particular,
        # it deliberately chooses one side of an ambiguous DST fold. Validate
        # the local wall-clock contract, then retain the explicit offsets from
        # the immutable snapshot instead of re-inferring the fold in Python.
        start_zone = slot.start.tzinfo
        end_zone = slot.end.tzinfo
        if start_zone is None or end_zone is None:
            raise SnapshotError(f"Generated slot {slot.id} has no timezone")
        if start.astimezone(start_zone).replace(tzinfo=None) != slot.start.replace(
            tzinfo=None
        ) or end.astimezone(end_zone).replace(tzinfo=None) != slot.end.replace(
            tzinfo=None
        ):
            raise SnapshotError(
                f"Resolved slot {slot.id} is outside its shift wall-clock time"
            )
        # Keep the database-selected instant/fold, but attach the IANA zones
        # from Matrix. A fixed offset would make local-time rules drift when a
        # shift crosses a DST boundary (for example 22:00+02 -> 06:00+01).
        authoritative = replace(
            slot,
            start=start.astimezone(start_zone),
            end=end.astimezone(end_zone),
        )
        expected = {
            "demandId": slot.demand_id,
            "occurrenceId": slot.occurrence_id,
            "seatIndex": slot.seat_index + 1,
            "date": slot.date.isoformat(),
            "shiftTemplateId": slot.shift_template_id,
            "locationId": slot.location_id,
            "roleId": slot.role_id,
            "dutyIds": list(slot.duty_ids),
            "durationMinutes": authoritative.duration_minutes,
        }
        for key, value in expected.items():
            actual = raw.get(key)
            if key == "dutyIds":
                actual = sorted(str(item) for item in (actual or []))
                value = sorted(value)
            elif key == "seatIndex" or key == "durationMinutes":
                try:
                    actual = int(actual)
                except (TypeError, ValueError) as exc:
                    raise SnapshotError(
                        f"Resolved slot {slot.id} has invalid {key}"
                    ) from exc
            else:
                actual = str(actual)
            if actual != value:
                raise SnapshotError(
                    f"Resolved slot {slot.id} has {key}={actual!r}, expected {value!r}"
                )
        resolved.append(authoritative)
    return resolved
