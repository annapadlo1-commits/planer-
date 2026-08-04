from __future__ import annotations

import re
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
from datetime import date, datetime, time
from typing import Any


class SnapshotError(ValueError):
    """Raised when a snapshot cannot be interpreted safely."""


_MISSING = object()

# ISO 4217 alphabetic codes.  The snapshot carries one currency for every
# amount, so accepting an arbitrary three-letter token would make otherwise
# valid schedules financially ambiguous.
ISO_4217_CODES = frozenset(
    """
    AED AFN ALL AMD ANG AOA ARS AUD AWG AZN BAM BBD BDT BGN BHD BIF BMD BND
    BOB BOV BRL BSD BTN BWP BYN BZD CAD CDF CHE CHF CHW CLF CLP CNY COP COU
    CRC CUC CUP CVE CZK DJF DKK DOP DZD EGP ERN ETB EUR FJD FKP GBP GEL GHS
    GIP GMD GNF GTQ GYD HKD HNL HTG HUF IDR ILS INR IQD IRR ISK JMD JOD JPY
    KES KGS KHR KMF KPW KRW KWD KYD KZT LAK LBP LKR LRD LSL LYD MAD MDL MGA
    MKD MMK MNT MOP MRU MUR MVR MWK MXN MXV MYR MZN NAD NGN NIO NOK NPR NZD
    OMR PAB PEN PGK PHP PKR PLN PYG QAR RON RSD RUB RWF SAR SBD SCR SDG SEK
    SGD SHP SLE SLL SOS SRD SSP STN SVC SYP SZL THB TJS TMT TND TOP TRY TTD
    TWD TZS UAH UGX USD USN UYI UYU UYW UZS VED VES VND VUV WST XAF XAG XAU
    XBA XBB XBC XBD XCD XDR XOF XPD XPF XPT XSU XTS XUA XXX YER ZAR ZMW ZWG
    ZWL
    """.split()  # noqa: SIM905 - compact audited ISO code table
)


def _pick(raw: Mapping[str, Any], *names: str, default: Any = _MISSING) -> Any:
    for name in names:
        if name in raw:
            return raw[name]
    if default is _MISSING:
        raise SnapshotError(f"Missing required field: {names[0]}")
    return default


def _items(value: Any, field_name: str) -> list[Mapping[str, Any]]:
    if value is None:
        return []
    if not isinstance(value, Sequence) or isinstance(value, (str, bytes, bytearray)):
        raise SnapshotError(f"{field_name} must be an array")
    result: list[Mapping[str, Any]] = []
    for item in value:
        if not isinstance(item, Mapping):
            raise SnapshotError(f"Every {field_name} item must be an object")
        result.append(item)
    return result


def _strings(value: Any) -> tuple[str, ...]:
    if value is None:
        return ()
    if isinstance(value, str):
        return (value,)
    if not isinstance(value, Sequence):
        raise SnapshotError("Expected an array of identifiers")
    return tuple(str(item) for item in value)


def _date(value: Any, field_name: str) -> date:
    if isinstance(value, datetime):
        return value.date()
    if isinstance(value, date):
        return value
    try:
        return date.fromisoformat(str(value))
    except (TypeError, ValueError) as exc:
        raise SnapshotError(f"{field_name} must be an ISO date") from exc


def _optional_date(value: Any, field_name: str) -> date | None:
    return None if value in (None, "") else _date(value, field_name)


def _datetime(value: Any, field_name: str) -> datetime:
    if isinstance(value, datetime):
        parsed = value
    else:
        try:
            parsed = datetime.fromisoformat(str(value))
        except (TypeError, ValueError) as exc:
            raise SnapshotError(f"{field_name} must be an ISO timestamp") from exc
    if parsed.tzinfo is None:
        raise SnapshotError(f"{field_name} must include a UTC offset")
    return parsed


def _clock(value: Any, field_name: str) -> time:
    if isinstance(value, time):
        return value.replace(tzinfo=None)
    try:
        return time.fromisoformat(str(value)).replace(tzinfo=None)
    except (TypeError, ValueError) as exc:
        raise SnapshotError(f"{field_name} must be an ISO local time") from exc


def _integer(value: Any, field_name: str, minimum: int | None = None) -> int:
    if isinstance(value, bool):
        raise SnapshotError(f"{field_name} must be an integer")
    try:
        parsed = int(value)
    except (TypeError, ValueError) as exc:
        raise SnapshotError(f"{field_name} must be an integer") from exc
    if minimum is not None and parsed < minimum:
        raise SnapshotError(f"{field_name} must be at least {minimum}")
    return parsed


def _currency(value: Any) -> str:
    parsed = str(value)
    if not re.fullmatch(r"[A-Z]{3}", parsed) or parsed not in ISO_4217_CODES:
        raise SnapshotError("currency must be an uppercase ISO 4217 code")
    return parsed


@dataclass(frozen=True)
class MatrixEntity:
    id: str
    code: str = ""

    @classmethod
    def from_dict(cls, raw: Mapping[str, Any]) -> MatrixEntity:
        return cls(id=str(_pick(raw, "id")), code=str(_pick(raw, "code", default="")))


@dataclass(frozen=True)
class Location:
    id: str
    code: str = ""
    timezone: str | None = None

    @classmethod
    def from_dict(cls, raw: Mapping[str, Any]) -> Location:
        timezone_value = _pick(raw, "timezone", default=None)
        return cls(
            id=str(_pick(raw, "id")),
            code=str(_pick(raw, "code", default="")),
            timezone=None if timezone_value in (None, "") else str(timezone_value),
        )


@dataclass(frozen=True)
class ObjectiveTerm:
    tier: int
    metric: str
    weight: int = 1
    direction: str = "MIN"
    tolerance: int = 0
    parameters: Mapping[str, Any] = field(default_factory=dict)

    @classmethod
    def from_dict(cls, raw: Mapping[str, Any]) -> ObjectiveTerm:
        direction = str(_pick(raw, "direction", default="MIN")).upper()
        if direction not in {"MIN", "MAX"}:
            raise SnapshotError("Objective direction must be MIN or MAX")
        weight = _integer(_pick(raw, "weight", default=1), "objective weight", 0)
        tolerance = _integer(
            _pick(raw, "tolerance", default=0), "objective tolerance", 0
        )
        parameters_raw = _pick(raw, "parameters", default={})
        if not isinstance(parameters_raw, Mapping):
            raise SnapshotError("Objective parameters must be an object")
        parameters = dict(parameters_raw)
        supported_parameters = {"target", "targetValue"}
        unsupported = set(parameters) - supported_parameters
        if unsupported:
            raise SnapshotError(
                f"Unsupported objective parameters: {sorted(unsupported)}"
            )
        if "target" in parameters and "targetValue" in parameters:
            raise SnapshotError("Objective target and targetValue are aliases")
        if parameters:
            target = parameters.get("targetValue", parameters.get("target"))
            parameters = {"targetValue": _integer(target, "objective targetValue", 0)}
            if direction != "MIN":
                raise SnapshotError("A targetValue objective must use MIN direction")
        return cls(
            tier=_integer(_pick(raw, "tier", default=1), "objective tier", 1),
            metric=str(_pick(raw, "metric")).upper(),
            weight=weight,
            direction=direction,
            tolerance=tolerance,
            parameters=parameters,
        )


@dataclass(frozen=True)
class Strategy:
    id: str
    code: str
    label: str
    sort_order: int
    objective_terms: tuple[ObjectiveTerm, ...]
    time_limit_seconds: int | None = None
    random_seed: int | None = None

    @classmethod
    def from_dict(cls, raw: Mapping[str, Any], index: int) -> Strategy:
        terms = tuple(
            ObjectiveTerm.from_dict(item)
            for item in _items(
                _pick(raw, "objectiveTerms", "objective_terms", default=[]),
                "objectiveTerms",
            )
        )
        limit_raw = _pick(raw, "timeLimitSeconds", "time_limit_seconds", default=None)
        seed_raw = _pick(raw, "randomSeed", "random_seed", default=None)
        return cls(
            id=str(_pick(raw, "id")),
            code=str(_pick(raw, "code", default=f"STRATEGY_{index + 1}")),
            label=str(_pick(raw, "label", "name", default=f"Variant {index + 1}")),
            sort_order=_integer(
                _pick(raw, "sortOrder", "sort_order", default=index), "sortOrder", 0
            ),
            objective_terms=terms,
            time_limit_seconds=(
                None
                if limit_raw is None
                else _integer(limit_raw, "timeLimitSeconds", 1)
            ),
            random_seed=None
            if seed_raw is None
            else _integer(seed_raw, "randomSeed", 0),
        )


@dataclass(frozen=True)
class ShiftTemplate:
    id: str
    location_id: str
    start_time: time
    end_time: time
    weekdays: tuple[int, ...]
    ends_next_day: bool = False
    shift_period: str = "MIDDLE"
    # Business order of shifts within a location/day.  This is deliberately
    # unrelated to how many shifts one employee may work: a Matrix may contain
    # any number of templates, while an employee may still work only one
    # primary shift per calendar day.
    sequence_order: int | None = None

    @classmethod
    def from_dict(cls, raw: Mapping[str, Any]) -> ShiftTemplate:
        weekdays = tuple(
            _integer(value, "weekday", 1)
            for value in _pick(raw, "weekdays", default=[1, 2, 3, 4, 5, 6, 7])
        )
        if any(value > 7 for value in weekdays):
            raise SnapshotError("weekdays must use ISO values 1 through 7")
        shift_period = str(
            _pick(raw, "shiftPeriod", "shift_period", default="MIDDLE")
        ).upper()
        if shift_period not in {"MORNING", "MIDDLE", "EVENING"}:
            raise SnapshotError("shiftPeriod must be MORNING, MIDDLE or EVENING")
        sequence_order_raw = _pick(
            raw, "sequenceOrder", "sequence_order", "sortOrder", "sort_order",
            default=None,
        )
        return cls(
            id=str(_pick(raw, "id")),
            location_id=str(_pick(raw, "locationId", "location_id")),
            start_time=_clock(_pick(raw, "startTime", "start_time"), "startTime"),
            end_time=_clock(_pick(raw, "endTime", "end_time"), "endTime"),
            weekdays=weekdays,
            ends_next_day=bool(
                _pick(raw, "endsNextDay", "ends_next_day", default=False)
            ),
            shift_period=shift_period,
            sequence_order=(
                None
                if sequence_order_raw is None
                else _integer(sequence_order_raw, "sequenceOrder", 0)
            ),
        )


@dataclass(frozen=True)
class Demand:
    id: str
    shift_template_id: str
    role_id: str
    duty_ids: tuple[str, ...]
    required_count: int
    dates: tuple[date, ...] = ()
    date_start: date | None = None
    date_end: date | None = None

    @classmethod
    def from_dict(cls, raw: Mapping[str, Any], index: int) -> Demand:
        dates = tuple(
            _date(value, "demand date") for value in _pick(raw, "dates", default=[])
        )
        return cls(
            id=str(_pick(raw, "id", default=f"demand-{index + 1}")),
            shift_template_id=str(_pick(raw, "shiftTemplateId", "shift_template_id")),
            role_id=str(_pick(raw, "roleId", "role_id")),
            duty_ids=tuple(
                sorted(set(_strings(_pick(raw, "dutyIds", "duty_ids", default=[]))))
            ),
            required_count=_integer(
                _pick(raw, "requiredCount", "required_count"), "requiredCount", 0
            ),
            dates=dates,
            date_start=_optional_date(
                _pick(raw, "dateStart", "date_start", default=None), "dateStart"
            ),
            date_end=_optional_date(
                _pick(raw, "dateEnd", "date_end", default=None), "dateEnd"
            ),
        )


@dataclass(frozen=True)
class EmployeeRoleGrant:
    role_id: str
    valid_from: date | None = None
    valid_to: date | None = None

    @classmethod
    def from_dict(cls, raw: Mapping[str, Any]) -> EmployeeRoleGrant:
        valid_from = _optional_date(
            _pick(raw, "validFrom", "valid_from", default=None), "role validFrom"
        )
        valid_to = _optional_date(
            _pick(raw, "validTo", "valid_to", default=None), "role validTo"
        )
        if valid_from and valid_to and valid_to < valid_from:
            raise SnapshotError("Role grant validTo cannot precede validFrom")
        return cls(
            role_id=str(_pick(raw, "roleId", "role_id")),
            valid_from=valid_from,
            valid_to=valid_to,
        )

    def active_on(self, day: date) -> bool:
        return (self.valid_from is None or self.valid_from <= day) and (
            self.valid_to is None or day <= self.valid_to
        )


@dataclass(frozen=True)
class EmployeeLocationGrant:
    location_id: str
    standard_allowed: bool
    overtime_allowed: bool
    valid_from: date | None = None
    valid_to: date | None = None

    @classmethod
    def from_dict(cls, raw: Mapping[str, Any]) -> EmployeeLocationGrant:
        valid_from = _optional_date(
            _pick(raw, "validFrom", "valid_from", default=None),
            "location validFrom",
        )
        valid_to = _optional_date(
            _pick(raw, "validTo", "valid_to", default=None), "location validTo"
        )
        if valid_from and valid_to and valid_to < valid_from:
            raise SnapshotError("Location grant validTo cannot precede validFrom")
        return cls(
            location_id=str(_pick(raw, "locationId", "location_id")),
            standard_allowed=bool(_pick(raw, "standardAllowed", "standard_allowed")),
            overtime_allowed=bool(_pick(raw, "overtimeAllowed", "overtime_allowed")),
            valid_from=valid_from,
            valid_to=valid_to,
        )

    def active_on(self, day: date) -> bool:
        return (self.valid_from is None or self.valid_from <= day) and (
            self.valid_to is None or day <= self.valid_to
        )


@dataclass(frozen=True)
class EmployeeDutyCapability:
    duty_id: str
    role_id: str | None = None
    location_id: str | None = None
    valid_from: date | None = None
    valid_to: date | None = None

    @classmethod
    def from_dict(cls, raw: Mapping[str, Any]) -> EmployeeDutyCapability:
        role_id = _pick(raw, "roleId", "role_id", default=None)
        location_id = _pick(raw, "locationId", "location_id", default=None)
        valid_from = _optional_date(
            _pick(raw, "validFrom", "valid_from", default=None), "duty validFrom"
        )
        valid_to = _optional_date(
            _pick(raw, "validTo", "valid_to", default=None), "duty validTo"
        )
        if valid_from and valid_to and valid_to < valid_from:
            raise SnapshotError("Duty grant validTo cannot precede validFrom")
        return cls(
            duty_id=str(_pick(raw, "dutyId", "duty_id")),
            role_id=None if role_id in (None, "") else str(role_id),
            location_id=None if location_id in (None, "") else str(location_id),
            valid_from=valid_from,
            valid_to=valid_to,
        )

    def matches(self, duty_id: str, role_id: str, location_id: str, day: date) -> bool:
        return (
            self.duty_id == duty_id
            and (self.role_id is None or self.role_id == role_id)
            and (self.location_id is None or self.location_id == location_id)
            and (self.valid_from is None or self.valid_from <= day)
            and (self.valid_to is None or day <= self.valid_to)
        )


@dataclass(frozen=True)
class PayRatePeriod:
    valid_from: date
    valid_to: date | None
    base_rate_minor: int
    contract_code: str

    @classmethod
    def from_dict(cls, raw: Mapping[str, Any]) -> PayRatePeriod:
        valid_from = _date(_pick(raw, "validFrom", "valid_from"), "pay rate validFrom")
        valid_to = _optional_date(
            _pick(raw, "validTo", "valid_to", default=None), "pay rate validTo"
        )
        if valid_to and valid_to < valid_from:
            raise SnapshotError("Pay rate validTo cannot precede validFrom")
        return cls(
            valid_from=valid_from,
            valid_to=valid_to,
            base_rate_minor=_integer(
                _pick(raw, "baseRateMinor", "base_rate_minor"),
                "pay rate baseRateMinor",
                0,
            ),
            contract_code=str(_pick(raw, "contractCode", "contract_code")),
        )

    def active_on(self, day: date) -> bool:
        return self.valid_from <= day and (
            self.valid_to is None or day <= self.valid_to
        )


@dataclass(frozen=True)
class Employee:
    id: str
    role_ids: tuple[str, ...]
    role_grants: tuple[EmployeeRoleGrant, ...] | None
    duty_ids: tuple[str, ...]
    duty_capabilities: tuple[EmployeeDutyCapability, ...] | None
    location_ids: tuple[str, ...]
    location_grants: tuple[EmployeeLocationGrant, ...] | None
    home_location_ids: tuple[str, ...]
    base_hourly_rate_minor: int
    pay_rate_periods: tuple[PayRatePeriod, ...] | None
    contract_code: str = ""
    employment_start: date | None = None
    employment_end: date | None = None
    nominal_monthly_minutes: int | None = None
    maximum_monthly_minutes: int | None = None
    maximum_weekly_minutes: int | None = None
    maximum_shifts_per_day: int = 1
    maximum_consecutive_days: int | None = None
    minimum_rest_minutes: int | None = None
    no_weekends: bool = False
    only_morning_before_minute: int | None = None
    only_evening_after_minute: int | None = None
    preferred_shift_template_ids: tuple[str, ...] = ()
    avoided_shift_template_ids: tuple[str, ...] = ()
    blocked_shift_template_ids: tuple[str, ...] = ()
    preferred_location_ids: tuple[str, ...] = ()
    soft_day_off_dates: tuple[date, ...] = ()
    missing_availability_means_available: bool | None = None

    @classmethod
    def from_dict(cls, raw: Mapping[str, Any]) -> Employee:
        def optional_int(camel: str, snake: str) -> int | None:
            value = _pick(raw, camel, snake, default=None)
            return None if value is None else _integer(value, camel, 0)

        def structured_items(*names: str) -> list[Mapping[str, Any]] | None:
            name = next((candidate for candidate in names if candidate in raw), None)
            return None if name is None else _items(raw[name], names[0])

        capabilities_name = next(
            (
                name
                for name in (
                    "dutyGrants",
                    "duty_grants",
                    "dutyCapabilities",
                    "duty_capabilities",
                )
                if name in raw
            ),
            None,
        )
        duty_capabilities = (
            None
            if capabilities_name is None
            else tuple(
                EmployeeDutyCapability.from_dict(item)
                for item in _items(raw[capabilities_name], "dutyCapabilities")
            )
        )
        role_items = structured_items("roleGrants", "role_grants")
        location_items = structured_items("locationGrants", "location_grants")
        pay_rate_items = structured_items("payRatePeriods", "pay_rate_periods")
        role_grants = (
            None
            if role_items is None
            else tuple(EmployeeRoleGrant.from_dict(item) for item in role_items)
        )
        location_grants = (
            None
            if location_items is None
            else tuple(EmployeeLocationGrant.from_dict(item) for item in location_items)
        )
        pay_rate_periods = (
            None
            if pay_rate_items is None
            else tuple(
                sorted(
                    (PayRatePeriod.from_dict(item) for item in pay_rate_items),
                    key=lambda item: item.valid_from,
                )
            )
        )
        for previous, current in zip(
            pay_rate_periods or (), (pay_rate_periods or ())[1:], strict=False
        ):
            if previous.valid_to is None or previous.valid_to >= current.valid_from:
                raise SnapshotError("Employee pay rate periods cannot overlap")
        contract_code = str(
            _pick(raw, "contractCode", "contract_code", default="")
        ).upper()
        work_time_policy = str(
            _pick(raw, "workTimePolicy", "work_time_policy", default="")
        ).upper()
        is_flexible_contractor = contract_code in {"ZLECENIE", "B2B"} and (
            work_time_policy != "CUSTOM"
        )
        return cls(
            id=str(_pick(raw, "id")),
            role_ids=_strings(_pick(raw, "roleIds", "role_ids", default=[])),
            role_grants=role_grants,
            duty_ids=_strings(_pick(raw, "dutyIds", "duty_ids", default=[])),
            duty_capabilities=duty_capabilities,
            location_ids=_strings(
                _pick(raw, "locationIds", "location_ids", default=[])
            ),
            location_grants=location_grants,
            home_location_ids=_strings(
                _pick(raw, "homeLocationIds", "home_location_ids", default=[])
            ),
            base_hourly_rate_minor=_integer(
                _pick(raw, "baseHourlyRateMinor", "base_hourly_rate_minor", default=0),
                "baseHourlyRateMinor",
                0,
            ),
            pay_rate_periods=pay_rate_periods,
            contract_code=contract_code,
            employment_start=_optional_date(
                _pick(raw, "employmentStart", "employment_start", default=None),
                "employmentStart",
            ),
            employment_end=_optional_date(
                _pick(raw, "employmentEnd", "employment_end", default=None),
                "employmentEnd",
            ),
            nominal_monthly_minutes=None if is_flexible_contractor else optional_int(
                "nominalMonthlyMinutes", "nominal_monthly_minutes"
            ),
            maximum_monthly_minutes=None if is_flexible_contractor else optional_int(
                "maximumMonthlyMinutes", "maximum_monthly_minutes"
            ),
            maximum_weekly_minutes=None if is_flexible_contractor else optional_int(
                "maximumWeeklyMinutes", "maximum_weekly_minutes"
            ),
            maximum_shifts_per_day=_integer(
                _pick(raw, "maximumShiftsPerDay", "maximum_shifts_per_day", default=1),
                "maximumShiftsPerDay",
                1,
            ),
            maximum_consecutive_days=None if is_flexible_contractor else optional_int(
                "maximumConsecutiveDays", "maximum_consecutive_days"
            ),
            minimum_rest_minutes=0 if is_flexible_contractor else optional_int(
                "minimumRestMinutes", "minimum_rest_minutes"
            ),
            no_weekends=bool(_pick(raw, "noWeekends", "no_weekends", default=False)),
            only_morning_before_minute=optional_int(
                "onlyMorningBeforeMinute", "only_morning_before_minute"
            ),
            only_evening_after_minute=optional_int(
                "onlyEveningAfterMinute", "only_evening_after_minute"
            ),
            preferred_shift_template_ids=_strings(
                _pick(
                    raw,
                    "preferredShiftTemplateIds",
                    "preferred_shift_template_ids",
                    default=[],
                )
            ),
            avoided_shift_template_ids=_strings(
                _pick(
                    raw,
                    "avoidedShiftTemplateIds",
                    "avoided_shift_template_ids",
                    default=[],
                )
            ),
            blocked_shift_template_ids=_strings(
                _pick(
                    raw,
                    "blockedShiftTemplateIds",
                    "blocked_shift_template_ids",
                    default=[],
                )
            ),
            preferred_location_ids=_strings(
                _pick(raw, "preferredLocationIds", "preferred_location_ids", default=[])
            ),
            soft_day_off_dates=tuple(
                _date(value, "softDayOffDate")
                for value in _pick(
                    raw, "softDayOffDates", "soft_day_off_dates", default=[]
                )
            ),
            missing_availability_means_available=_pick(
                raw,
                "missingAvailabilityMeansAvailable",
                "missing_availability_means_available",
                default=None,
            ),
        )

    def role_allowed_on(self, role_id: str, day: date) -> bool:
        if self.role_grants is None:
            return role_id in self.role_ids
        return any(
            grant.role_id == role_id and grant.active_on(day)
            for grant in self.role_grants
        )

    def location_allowed_on(self, location_id: str, day: date) -> bool:
        if self.location_grants is None:
            return location_id in self.location_ids
        return any(
            grant.location_id == location_id
            and grant.standard_allowed
            and grant.active_on(day)
            for grant in self.location_grants
        )

    def duties_allowed_on(
        self, duty_ids: Sequence[str], role_id: str, location_id: str, day: date
    ) -> bool:
        if self.duty_capabilities is None:
            return set(duty_ids).issubset(self.duty_ids)
        return all(
            any(
                capability.matches(duty_id, role_id, location_id, day)
                for capability in self.duty_capabilities
            )
            for duty_id in duty_ids
        )

    def pay_rate_on(self, day: date) -> tuple[int, str]:
        if self.pay_rate_periods is not None:
            matching = [
                period for period in self.pay_rate_periods if period.active_on(day)
            ]
            if matching:
                period = matching[0]
                return period.base_rate_minor, period.contract_code
        return self.base_hourly_rate_minor, self.contract_code


@dataclass(frozen=True)
class AvailabilityWindow:
    employee_id: str
    start: datetime
    end: datetime

    @classmethod
    def from_dict(cls, raw: Mapping[str, Any]) -> AvailabilityWindow:
        start = _datetime(
            _pick(raw, "start", "startsAt", "starts_at"), "availability start"
        )
        end = _datetime(_pick(raw, "end", "endsAt", "ends_at"), "availability end")
        if end <= start:
            raise SnapshotError("Availability window must have positive duration")
        return cls(
            employee_id=str(_pick(raw, "employeeId", "employee_id")),
            start=start,
            end=end,
        )


@dataclass(frozen=True)
class HardBlock:
    employee_id: str
    start: datetime | None = None
    end: datetime | None = None
    date_start: date | None = None
    date_end: date | None = None

    @classmethod
    def from_dict(cls, raw: Mapping[str, Any]) -> HardBlock:
        start_raw = _pick(raw, "start", "startsAt", "starts_at", default=None)
        end_raw = _pick(raw, "end", "endsAt", "ends_at", default=None)
        date_start = _optional_date(
            _pick(raw, "dateStart", "date_start", default=None), "block dateStart"
        )
        date_end = _optional_date(
            _pick(raw, "dateEnd", "date_end", default=None), "block dateEnd"
        )
        start = None if start_raw is None else _datetime(start_raw, "block start")
        end = None if end_raw is None else _datetime(end_raw, "block end")
        if (start is None) != (end is None):
            raise SnapshotError("Hard block needs both start and end")
        if start is not None and end <= start:
            raise SnapshotError("Hard block must have positive duration")
        if start is None and date_start is None:
            raise SnapshotError("Hard block needs an interval or a date range")
        return cls(
            employee_id=str(_pick(raw, "employeeId", "employee_id")),
            start=start,
            end=end,
            date_start=date_start,
            date_end=date_end or date_start,
        )


@dataclass(frozen=True)
class ExternalAssignment:
    employee_id: str
    start: datetime
    end: datetime

    @classmethod
    def from_dict(cls, raw: Mapping[str, Any]) -> ExternalAssignment:
        start = _datetime(
            _pick(raw, "start", "startsAt", "starts_at"), "assignment start"
        )
        end = _datetime(_pick(raw, "end", "endsAt", "ends_at"), "assignment end")
        if end <= start:
            raise SnapshotError("Existing assignment must have positive duration")
        return cls(
            employee_id=str(_pick(raw, "employeeId", "employee_id")),
            start=start,
            end=end,
        )


@dataclass(frozen=True)
class LockedAssignment:
    slot_id: str
    employee_id: str

    @classmethod
    def from_dict(cls, raw: Mapping[str, Any]) -> LockedAssignment:
        return cls(
            slot_id=str(_pick(raw, "slotId", "slot_id")),
            employee_id=str(_pick(raw, "employeeId", "employee_id")),
        )


@dataclass(frozen=True)
class BaselineAssignment:
    slot_id: str
    employee_id: str | None

    @classmethod
    def from_dict(cls, raw: Mapping[str, Any]) -> BaselineAssignment:
        employee_id = _pick(raw, "employeeId", "employee_id", default=None)
        return cls(
            slot_id=str(_pick(raw, "slotId", "slot_id")),
            employee_id=None if employee_id is None else str(employee_id),
        )


@dataclass(frozen=True)
class PayCondition:
    field: str
    operator: str
    value: Any

    def __post_init__(self) -> None:
        identifier_fields = {
            "role_id",
            "location_id",
            "shift_template_id",
            "scenario_id",
            "employee_id",
        }
        numeric_fields = {"weekday", "duration_minutes"}
        scalar_operators = {"EQ", "NE"}
        membership_operators = {"IN", "NOT_IN"}

        def is_text(value: Any) -> bool:
            return isinstance(value, str) and bool(value)

        def is_text_array(value: Any) -> bool:
            return (
                isinstance(value, Sequence)
                and not isinstance(value, (str, bytes, bytearray))
                and all(is_text(item) for item in value)
            )

        def is_integer(value: Any) -> bool:
            return isinstance(value, int) and not isinstance(value, bool) and value >= 0

        def valid_numeric(value: Any) -> bool:
            return is_integer(value) and (self.field != "weekday" or 1 <= value <= 7)

        if self.field in identifier_fields:
            valid = (self.operator in scalar_operators and is_text(self.value)) or (
                self.operator in membership_operators and is_text_array(self.value)
            )
        elif self.field == "duty_ids":
            valid = (self.operator == "CONTAINS" and is_text(self.value)) or (
                self.operator in {"CONTAINS_ANY", "CONTAINS_ALL"}
                and is_text_array(self.value)
            )
        elif self.field == "contract_code":
            valid = (self.operator in scalar_operators and is_text(self.value)) or (
                self.operator in membership_operators and is_text_array(self.value)
            )
        elif self.field in numeric_fields:
            valid = (
                self.operator in scalar_operators | {"GTE", "LTE"}
                and valid_numeric(self.value)
            ) or (
                self.operator in membership_operators
                and isinstance(self.value, Sequence)
                and not isinstance(self.value, (str, bytes, bytearray))
                and all(valid_numeric(item) for item in self.value)
            )
        elif self.field == "local_time":
            valid = (
                self.operator == "OVERLAPS_TIME"
                and isinstance(self.value, Mapping)
                and set(self.value) == {"start", "end"}
                and all(
                    isinstance(self.value[key], str)
                    and re.fullmatch(
                        r"(?:[01][0-9]|2[0-3]):[0-5][0-9](?::[0-5][0-9])?",
                        self.value[key],
                    )
                    for key in ("start", "end")
                )
            )
        else:
            valid = False
        if not valid:
            raise SnapshotError(
                f"Unsupported pay condition contract: {self.field}/{self.operator}"
            )

    @classmethod
    def from_dict(cls, raw: Mapping[str, Any]) -> PayCondition:
        return cls(
            field=str(_pick(raw, "field")).lower(),
            operator=str(_pick(raw, "operator", default="EQ")).upper(),
            value=_pick(raw, "value", default=None),
        )


@dataclass(frozen=True)
class PayRule:
    id: str
    calculation_type: str
    values: Mapping[str, Any]
    conditions: tuple[PayCondition, ...]
    stacking_group: str
    stacking_mode: str
    priority: int
    active: bool
    effective_from: date | None = None
    effective_to: date | None = None

    @classmethod
    def from_dict(cls, raw: Mapping[str, Any], index: int) -> PayRule:
        rule_id = str(_pick(raw, "id", default=f"pay-rule-{index + 1}"))
        values = _pick(raw, "values", "parameters", default={})
        if not isinstance(values, Mapping):
            raise SnapshotError("Pay rule values must be an object")
        calculation_type = str(
            _pick(raw, "calculationType", "calculation_type")
        ).upper()
        calculation_type = {
            "AMOUNT_PER_HOUR": "PER_HOUR",
            "PERCENT_OF_BASE": "PERCENT_BASE",
            "RATE_MULTIPLIER": "MULTIPLIER",
            "THRESHOLD_AMOUNT": "SHIFT_DURATION_THRESHOLD_PER_HOUR",
        }.get(calculation_type, calculation_type)
        conditions = [
            PayCondition.from_dict(item)
            for item in _items(_pick(raw, "conditions", default=[]), "conditions")
        ]
        for key, field_name, operator in (
            ("roleIds", "role_id", "IN"),
            ("dutyIds", "duty_ids", "CONTAINS_ANY"),
            ("locationIds", "location_id", "IN"),
            ("shiftTemplateIds", "shift_template_id", "IN"),
        ):
            identifiers = _pick(raw, key, default=[])
            if identifiers:
                conditions.append(
                    PayCondition(
                        field=field_name, operator=operator, value=list(identifiers)
                    )
                )
        day_mask = _pick(raw, "dayMask", "day_mask", default=[])
        if day_mask:
            conditions.append(
                PayCondition(field="weekday", operator="IN", value=list(day_mask))
            )
        local_start = _pick(raw, "localStart", "local_start", default=None)
        local_end = _pick(raw, "localEnd", "local_end", default=None)
        if (local_start is None) != (local_end is None):
            raise SnapshotError("Pay rule localStart and localEnd must be set together")
        if local_start is not None:
            conditions.append(
                PayCondition(
                    field="local_time",
                    operator="OVERLAPS_TIME",
                    value={"start": str(local_start), "end": str(local_end)},
                )
            )
        stacking_group = _pick(raw, "stackingGroup", "stacking_group", default=None)
        return cls(
            id=rule_id,
            calculation_type=calculation_type,
            values=dict(values),
            conditions=tuple(conditions),
            stacking_group=(
                rule_id if stacking_group in (None, "") else str(stacking_group)
            ),
            stacking_mode=str(
                _pick(raw, "stackingMode", "stacking_mode", default="STACK")
            ).upper(),
            priority=_integer(
                _pick(raw, "priority", default=index), "pay rule priority", 0
            ),
            active=bool(_pick(raw, "active", default=True)),
            effective_from=_optional_date(
                _pick(raw, "effectiveFrom", "effective_from", default=None),
                "effectiveFrom",
            ),
            effective_to=_optional_date(
                _pick(raw, "effectiveTo", "effective_to", default=None),
                "effectiveTo",
            ),
        )


@dataclass(frozen=True)
class Budget:
    id: str
    amount_minor: int
    hard: bool = True
    location_id: str | None = None
    role_id: str | None = None
    duty_id: str | None = None

    @classmethod
    def from_dict(
        cls,
        raw: Mapping[str, Any] | None,
        *,
        default_id: str | None = None,
        allow_disabled: bool = False,
    ) -> Budget | None:
        if raw is None:
            return None
        amount = _pick(raw, "amountMinor", "amount_minor", default=None)
        hard = bool(_pick(raw, "hard", default=True))
        if amount is None:
            if allow_disabled and not hard:
                return None
            raise SnapshotError("A budget requires amountMinor")
        budget_id = _pick(raw, "id", default=default_id)
        if budget_id in (None, ""):
            raise SnapshotError("A scoped budget requires id")

        def optional_id(camel: str, snake: str) -> str | None:
            value = _pick(raw, camel, snake, default=None)
            return None if value in (None, "") else str(value)

        return cls(
            id=str(budget_id),
            amount_minor=_integer(amount, "budget amountMinor", 0),
            hard=hard,
            location_id=optional_id("locationId", "location_id"),
            role_id=optional_id("roleId", "role_id"),
            duty_id=optional_id("dutyId", "duty_id"),
        )

    def matches(self, slot: Any) -> bool:
        return (
            (self.location_id is None or slot.location_id == self.location_id)
            and (self.role_id is None or slot.role_id == self.role_id)
            and (self.duty_id is None or self.duty_id in slot.duty_ids)
        )

    def scope(self) -> dict[str, str]:
        scope: dict[str, str] = {}
        if self.location_id is not None:
            scope["locationId"] = self.location_id
        if self.role_id is not None:
            scope["roleId"] = self.role_id
        if self.duty_id is not None:
            scope["dutyId"] = self.duty_id
        return scope


@dataclass(frozen=True)
class Settings:
    timezone: str
    missing_availability_means_available: bool = True
    default_minimum_rest_minutes: int = 660
    require_optimal: bool = True
    random_seed: int = 1
    standby_tiers_per_role_day: int = 0

    def __post_init__(self) -> None:
        if self.standby_tiers_per_role_day > 2:
            raise SnapshotError("standbyTiersPerRoleDay must be between 0 and 2")

    @classmethod
    def from_dict(cls, raw: Mapping[str, Any]) -> Settings:
        return cls(
            timezone=str(_pick(raw, "timezone")),
            missing_availability_means_available=bool(
                _pick(
                    raw,
                    "missingAvailabilityMeansAvailable",
                    "missing_availability_means_available",
                    default=True,
                )
            ),
            default_minimum_rest_minutes=_integer(
                _pick(
                    raw,
                    "defaultMinimumRestMinutes",
                    "default_minimum_rest_minutes",
                    default=660,
                ),
                "defaultMinimumRestMinutes",
                0,
            ),
            require_optimal=bool(
                _pick(raw, "requireOptimal", "require_optimal", default=True)
            ),
            random_seed=_integer(
                _pick(raw, "randomSeed", "random_seed", default=1), "randomSeed", 0
            ),
            standby_tiers_per_role_day=_integer(
                _pick(
                    raw,
                    "standbyTiersPerRoleDay",
                    "standby_tiers_per_role_day",
                    default=0,
                ),
                "standbyTiersPerRoleDay",
                0,
            ),
        )


@dataclass(frozen=True)
class Snapshot:
    schema_version: int
    run_id: str
    matrix_version_id: str
    scenario_id: str
    period_start: date
    period_end: date
    currency: str
    settings: Settings
    strategies: tuple[Strategy, ...]
    roles: tuple[MatrixEntity, ...]
    duties: tuple[MatrixEntity, ...]
    locations: tuple[Location, ...]
    shift_templates: tuple[ShiftTemplate, ...]
    demand: tuple[Demand, ...]
    employees: tuple[Employee, ...]
    availability_windows: tuple[AvailabilityWindow, ...]
    hard_blocks: tuple[HardBlock, ...]
    pay_rules: tuple[PayRule, ...]
    budgets: tuple[Budget, ...]
    budget: Budget | None
    locked_assignments: tuple[LockedAssignment, ...]
    baseline_assignments: tuple[BaselineAssignment, ...]
    external_assignments: tuple[ExternalAssignment, ...]
    raw: Mapping[str, Any] = field(repr=False, compare=False)

    @classmethod
    def from_dict(cls, raw: Mapping[str, Any]) -> Snapshot:
        version = _integer(
            _pick(raw, "schemaVersion", "schema_version"), "schemaVersion"
        )
        if version != 2:
            raise SnapshotError(
                f"Unsupported schemaVersion {version}; worker requires 2"
            )
        month = _pick(raw, "month", default=None)
        period_start_raw = _pick(raw, "periodStart", "period_start", default=None)
        period_end_raw = _pick(raw, "periodEnd", "period_end", default=None)
        if period_start_raw is None or period_end_raw is None:
            if not month:
                raise SnapshotError("Snapshot needs periodStart/periodEnd or month")
            try:
                year, month_number = (int(part) for part in str(month).split("-", 1))
                period_start = date(year, month_number, 1)
                if month_number == 12:
                    next_month = date(year + 1, 1, 1)
                else:
                    next_month = date(year, month_number + 1, 1)
                period_end = date.fromordinal(next_month.toordinal() - 1)
            except (TypeError, ValueError) as exc:
                raise SnapshotError("month must use YYYY-MM") from exc
        else:
            period_start = _date(period_start_raw, "periodStart")
            period_end = _date(period_end_raw, "periodEnd")
        if period_end < period_start:
            raise SnapshotError("periodEnd cannot precede periodStart")

        currency = _currency(_pick(raw, "currency"))

        settings_raw = _pick(raw, "settings")
        if not isinstance(settings_raw, Mapping):
            raise SnapshotError("settings must be an object")
        strategy_items = _items(_pick(raw, "strategies", default=[]), "strategies")
        strategies = tuple(
            Strategy.from_dict(item, index) for index, item in enumerate(strategy_items)
        )
        if not strategies:
            raise SnapshotError("Snapshot must contain at least one active strategy")

        if "budgets" not in raw:
            legacy_budget = Budget.from_dict(
                _pick(raw, "budget", default=None),
                default_id="legacy-global-budget",
                allow_disabled=True,
            )
            budgets = () if legacy_budget is None else (legacy_budget,)
        else:
            legacy_budget = None
            budgets = tuple(
                budget
                for item in _items(raw["budgets"], "budgets")
                if (budget := Budget.from_dict(item)) is not None
            )

        def entities(name: str) -> tuple[MatrixEntity, ...]:
            return tuple(
                MatrixEntity.from_dict(item)
                for item in _items(_pick(raw, name, default=[]), name)
            )

        return cls(
            schema_version=version,
            run_id=str(_pick(raw, "runId", "run_id")),
            matrix_version_id=str(
                _pick(raw, "matrixVersionId", "matrix_version_id", default="")
            ),
            scenario_id=str(_pick(raw, "scenarioId", "scenario_id")),
            period_start=period_start,
            period_end=period_end,
            currency=currency,
            settings=Settings.from_dict(settings_raw),
            strategies=strategies,
            roles=entities("roles"),
            duties=entities("duties"),
            locations=tuple(
                Location.from_dict(item)
                for item in _items(_pick(raw, "locations", default=[]), "locations")
            ),
            shift_templates=tuple(
                ShiftTemplate.from_dict(item)
                for item in _items(
                    _pick(raw, "shiftTemplates", "shift_templates", default=[]),
                    "shiftTemplates",
                )
            ),
            demand=tuple(
                Demand.from_dict(item, index)
                for index, item in enumerate(
                    _items(_pick(raw, "demand", default=[]), "demand")
                )
            ),
            employees=tuple(
                Employee.from_dict(item)
                for item in _items(_pick(raw, "employees", default=[]), "employees")
            ),
            availability_windows=tuple(
                AvailabilityWindow.from_dict(item)
                for item in _items(
                    _pick(
                        raw, "availabilityWindows", "availability_windows", default=[]
                    ),
                    "availabilityWindows",
                )
            ),
            hard_blocks=tuple(
                HardBlock.from_dict(item)
                for item in _items(
                    _pick(raw, "hardBlocks", "hard_blocks", default=[]), "hardBlocks"
                )
            ),
            pay_rules=tuple(
                PayRule.from_dict(item, index)
                for index, item in enumerate(
                    _items(_pick(raw, "payRules", "pay_rules", default=[]), "payRules")
                )
            ),
            budgets=budgets,
            budget=legacy_budget,
            locked_assignments=tuple(
                LockedAssignment.from_dict(item)
                for item in _items(
                    _pick(raw, "lockedAssignments", "locked_assignments", default=[]),
                    "lockedAssignments",
                )
            ),
            baseline_assignments=tuple(
                BaselineAssignment.from_dict(item)
                for item in _items(
                    _pick(
                        raw, "baselineAssignments", "baseline_assignments", default=[]
                    ),
                    "baselineAssignments",
                )
            ),
            external_assignments=tuple(
                ExternalAssignment.from_dict(item)
                for item in _items(
                    _pick(
                        raw, "externalAssignments", "external_assignments", default=[]
                    ),
                    "externalAssignments",
                )
            ),
            raw=dict(raw),
        )


@dataclass(frozen=True)
class Assignment:
    slot_id: str
    employee_id: str
    cost_units: int
    cost_components: tuple[Mapping[str, Any], ...] = ()

    def to_dict(self) -> dict[str, Any]:
        return {
            "slotId": self.slot_id,
            "employeeId": self.employee_id,
            "costUnits": self.cost_units,
            "costComponents": [dict(component) for component in self.cost_components],
        }


@dataclass(frozen=True)
class VariantResult:
    strategy_id: str
    strategy_code: str
    label: str
    sort_order: int
    assignments: tuple[Assignment, ...]
    unfilled_slot_ids: tuple[str, ...]
    metrics: Mapping[str, int]
    stage_objectives: tuple[Mapping[str, Any], ...]
    optimal: bool
    solution_hash: str
    equivalent_to_strategy_id: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "schemaVersion": 2,
            "strategyId": self.strategy_id,
            "strategyCode": self.strategy_code,
            "label": self.label,
            "sortOrder": self.sort_order,
            "assignments": [assignment.to_dict() for assignment in self.assignments],
            "unfilledSlotIds": list(self.unfilled_slot_ids),
            "metrics": dict(self.metrics),
            "stageObjectives": [dict(item) for item in self.stage_objectives],
            "optimal": self.optimal,
            "solutionHash": self.solution_hash,
            "equivalentToStrategyId": self.equivalent_to_strategy_id,
        }
