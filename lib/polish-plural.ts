export function polishTaskCount(count: number) {
  const absolute = Math.abs(Math.trunc(count));
  const lastTwo = absolute % 100;
  const last = absolute % 10;
  if (absolute === 1) return "1 zadanie";
  if (last >= 2 && last <= 4 && (lastTwo < 12 || lastTwo > 14)) {
    return `${absolute} zadania`;
  }
  return `${absolute} zadań`;
}

export function polishQueuedTaskSentence(count: number) {
  const absolute = Math.abs(Math.trunc(count));
  const lastTwo = absolute % 100;
  const last = absolute % 10;
  const usesPluralVerb = last >= 2 && last <= 4 && (lastTwo < 12 || lastTwo > 14);
  return `Przed tym grafikiem ${usesPluralVerb ? "są" : "jest"} jeszcze ${polishTaskCount(absolute)}`;
}
