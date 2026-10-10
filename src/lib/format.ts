const TICKS_PER_SECOND = 10_000_000;

export function secondsToTicks(seconds: number): number {
  return Math.round(
    Math.max(0, Number.isFinite(seconds) ? seconds : 0) * TICKS_PER_SECOND,
  );
}

export function ticksToSeconds(ticks: number): number {
  return Math.max(0, Number.isFinite(ticks) ? ticks : 0) / TICKS_PER_SECOND;
}

export function formatDuration(minutes: number): string {
  const whole = Math.max(0, Math.round(minutes));
  if (!whole) return "时长未知";
  if (whole < 60) return `${whole} 分钟`;
  const remainder = whole % 60;
  return `${Math.floor(whole / 60)} 小时${remainder ? ` ${remainder} 分钟` : ""}`;
}

export function formatTime(seconds: number): string {
  const value = Math.max(0, Math.floor(Number.isFinite(seconds) ? seconds : 0));
  const hours = Math.floor(value / 3600);
  const minutes = Math.floor((value % 3600) / 60);
  const remainder = String(value % 60).padStart(2, "0");
  return hours
    ? `${hours}:${String(minutes).padStart(2, "0")}:${remainder}`
    : `${minutes}:${remainder}`;
}
