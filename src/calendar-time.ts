const ISO_WITH_OFFSET_RE = /(Z|[+-]\d{2}:\d{2})$/i;

const WINDOWS_TZ_TO_IANA: Record<string, string> = {
  "AUS Eastern Standard Time": "Australia/Sydney",
  "Arab Standard Time": "Asia/Riyadh",
  "Central Europe Standard Time": "Europe/Budapest",
  "Central Standard Time": "America/Chicago",
  "China Standard Time": "Asia/Shanghai",
  "Eastern Standard Time": "America/New_York",
  "GMT Standard Time": "Europe/London",
  "India Standard Time": "Asia/Kolkata",
  "Mountain Standard Time": "America/Denver",
  "New Zealand Standard Time": "Pacific/Auckland",
  "Pacific Standard Time": "America/Los_Angeles",
  "Romance Standard Time": "Europe/Paris",
  "Tokyo Standard Time": "Asia/Tokyo",
  UTC: "UTC",
  "US Eastern Standard Time": "America/Indianapolis",
  "W. Europe Standard Time": "Europe/Berlin",
};

function normalizeTimeZone(timeZone?: string): string | undefined {
  if (!timeZone) {
    return undefined;
  }

  return WINDOWS_TZ_TO_IANA[timeZone] ?? timeZone;
}

function parseDateTimeParts(dateTime: string): number[] | null {
  const match = dateTime.match(
    /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2}))?/,
  );
  if (!match) {
    return null;
  }

  return [
    Number(match[1]),
    Number(match[2]),
    Number(match[3]),
    Number(match[4]),
    Number(match[5]),
    Number(match[6] ?? "0"),
  ];
}

function getTimeZoneOffsetMs(timeZone: string, instant: Date): number {
  const formatter = new Intl.DateTimeFormat("en-US", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hour12: false,
  });

  const parts = formatter
    .formatToParts(instant)
    .reduce<Record<string, string>>((acc, part) => {
      if (part.type !== "literal") {
        acc[part.type] = part.value;
      }
      return acc;
    }, {});

  const asUtc = Date.UTC(
    Number(parts.year),
    Number(parts.month) - 1,
    Number(parts.day),
    Number(parts.hour),
    Number(parts.minute),
    Number(parts.second),
  );

  return asUtc - instant.getTime();
}

export function parseCalendarDateTime(dateTime: string, timeZone?: string): Date {
  if (ISO_WITH_OFFSET_RE.test(dateTime)) {
    return new Date(dateTime);
  }

  const normalizedTimeZone = normalizeTimeZone(timeZone);
  const parts = parseDateTimeParts(dateTime);
  if (!normalizedTimeZone || !parts) {
    return new Date(dateTime);
  }

  const [year, month, day, hour, minute, second] = parts;
  const utcGuessMs = Date.UTC(year, month - 1, day, hour, minute, second);

  if (normalizedTimeZone === "UTC") {
    return new Date(utcGuessMs);
  }

  try {
    let result = new Date(utcGuessMs);
    let offsetMs = getTimeZoneOffsetMs(normalizedTimeZone, result);
    result = new Date(utcGuessMs - offsetMs);

    const correctedOffsetMs = getTimeZoneOffsetMs(normalizedTimeZone, result);
    if (correctedOffsetMs !== offsetMs) {
      offsetMs = correctedOffsetMs;
      result = new Date(utcGuessMs - offsetMs);
    }

    return result;
  } catch {
    return new Date(dateTime);
  }
}
