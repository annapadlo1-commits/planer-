export type EmployeeHomeAssignment = {
  id: string;
  date: string;
  startsAt: string;
  endsAt: string;
};

export type EmployeeHomeSwap = {
  status: string;
  targetEmployeeId?: string | null;
  acceptedByEmployeeId?: string | null;
  eligible: boolean;
  isMine: boolean;
};

export type EmployeeHomeSnapshot = {
  today: string;
  currentAssignmentId: string | null;
  nextAssignmentId: string | null;
  nextState: "NOW" | "UPCOMING" | "NONE";
  minutesUntilNext: number | null;
  todayShiftCount: number;
  weekShiftCount: number;
  weekMinutes: number;
  monthShiftCount: number;
  monthMinutes: number;
  weekendShiftCount: number;
  targetedSwapCount: number;
  openShiftCount: number;
  waitingLeaderCount: number;
};

function zonedIsoDate(value: Date, timezone: string) {
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat("en-CA", {
      timeZone: timezone,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
    }).formatToParts(value).filter(part => part.type !== "literal").map(part => [part.type, part.value]),
  );
  return `${parts.year}-${parts.month}-${parts.day}`;
}

function addIsoDays(value: string, days: number) {
  const date = new Date(`${value}T12:00:00Z`);
  date.setUTCDate(date.getUTCDate() + days);
  return date.toISOString().slice(0, 10);
}

function weekBounds(today: string) {
  const date = new Date(`${today}T12:00:00Z`);
  const mondayOffset = (date.getUTCDay() + 6) % 7;
  const start = addIsoDays(today, -mondayOffset);
  return { start, end: addIsoDays(start, 6) };
}

function assignmentMinutes(assignment: EmployeeHomeAssignment) {
  return Math.max(0, Math.round((new Date(assignment.endsAt).getTime() - new Date(assignment.startsAt).getTime()) / 60_000));
}

export function employeeHomeSnapshot({
  assignments,
  swaps,
  employeeId,
  timezone,
  now = new Date(),
}: {
  assignments: EmployeeHomeAssignment[];
  swaps: EmployeeHomeSwap[];
  employeeId?: string | null;
  timezone: string;
  now?: Date;
}): EmployeeHomeSnapshot {
  const nowMs = now.getTime();
  const today = zonedIsoDate(now, timezone);
  const ordered = [...assignments].sort((left, right) => new Date(left.startsAt).getTime() - new Date(right.startsAt).getTime());
  const current = ordered.find(assignment => new Date(assignment.startsAt).getTime() <= nowMs && new Date(assignment.endsAt).getTime() > nowMs) ?? null;
  const upcoming = ordered.find(assignment => new Date(assignment.startsAt).getTime() > nowMs) ?? null;
  const nearest = current ?? upcoming;
  const week = weekBounds(today);
  const weekAssignments = assignments.filter(assignment => assignment.date >= week.start && assignment.date <= week.end);
  const weekendShiftCount = assignments.filter(assignment => {
    const day = new Date(`${assignment.date}T12:00:00Z`).getUTCDay();
    return day === 0 || day === 6;
  }).length;
  const activeSwaps = swaps.filter(request => request.status === "OPEN");
  return {
    today,
    currentAssignmentId: current?.id ?? null,
    nextAssignmentId: nearest?.id ?? null,
    nextState: current ? "NOW" : upcoming ? "UPCOMING" : "NONE",
    minutesUntilNext: current ? 0 : upcoming ? Math.max(0, Math.ceil((new Date(upcoming.startsAt).getTime() - nowMs) / 60_000)) : null,
    todayShiftCount: assignments.filter(assignment => assignment.date === today).length,
    weekShiftCount: weekAssignments.length,
    weekMinutes: weekAssignments.reduce((sum, assignment) => sum + assignmentMinutes(assignment), 0),
    monthShiftCount: assignments.length,
    monthMinutes: assignments.reduce((sum, assignment) => sum + assignmentMinutes(assignment), 0),
    weekendShiftCount,
    targetedSwapCount: activeSwaps.filter(request => Boolean(employeeId) && request.targetEmployeeId === employeeId && !request.isMine).length,
    openShiftCount: activeSwaps.filter(request => !request.isMine && request.eligible).length,
    waitingLeaderCount: swaps.filter(request => request.status === "EMPLOYEE_ACCEPTED" && (request.isMine || Boolean(employeeId) && request.acceptedByEmployeeId === employeeId)).length,
  };
}
