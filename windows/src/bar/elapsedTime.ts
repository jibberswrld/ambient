/** "0:42", "12:05", "1:02:09". */
export function formatElapsedTime(startDate: Date, endDate: Date): string {
  const totalSeconds = Math.max(0, Math.floor((endDate.getTime() - startDate.getTime()) / 1000));
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;
  const twoDigits = (value: number) => String(value).padStart(2, '0');
  if (hours > 0) return `${hours}:${twoDigits(minutes)}:${twoDigits(seconds)}`;
  return `${minutes}:${twoDigits(seconds)}`;
}
