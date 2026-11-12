namespace IssuesTray.Issues;

internal sealed record CountPart(KindFilter Kind, string Text);

/// <summary>Text and colour decisions, with no UI types, so every rule lives in one place.</summary>
internal static class Fmt
{
    public static string Plural(int n, string one, string many) => n == 1 ? one : many;

    /// <summary>
    /// "now", "5m ago", "3h ago", "2d ago", "4w ago", "5mo ago", "1y ago". Always
    /// floored: an age should never claim more time has passed than actually has.
    /// </summary>
    public static string Age(DateTimeOffset when, DateTimeOffset now)
    {
        var span = now - when;
        var mins = (int)Math.Floor(span.TotalMinutes);
        if (mins < 1) return "now";
        if (mins < 60) return $"{mins}m ago";
        var hours = (int)Math.Floor(span.TotalHours);
        if (hours < 24) return $"{hours}h ago";
        var days = (int)Math.Floor(span.TotalDays);
        if (days < 14) return $"{days}d ago";
        // Thresholds are all in days on purpose. Written against each unit's own
        // counter they stop lining up once the counters truncate: "23mo ago" would be
        // followed a day later by "1y ago", and a months limit of 12 against a years
        // divisor of 365 yields "0y ago" for five weeks of the year.
        if (days < 63) return $"{days / 7}w ago";
        if (days < 365) return $"{days / 30}mo ago";
        return $"{days / 365}y ago";
    }

    private static readonly string[] RepoPalette =
    [
        "#4C9AFF", "#57D9A3", "#FFAB00", "#FF7452", "#B57BFF",
        "#00C7E6", "#F2789F", "#96C22D", "#FF8B00", "#79A3FF",
    ];

    /// <summary>A colour per repository, derived from its name so it is stable across
    /// runs (and the same the PowerShell version gave it).</summary>
    public static string RepoColor(string repo)
    {
        if (string.IsNullOrEmpty(repo)) return "#8A9199";
        var h = 0;
        foreach (var c in repo) h = (h * 31 + c) % 100000;
        return RepoPalette[h % RepoPalette.Length];
    }

    /// <summary>
    /// Terms are ANDed and matched anywhere, so “mon api” finds an issue in monde/api
    /// as readily as one titled “API” in monde/web, and the order they are typed in
    /// does not matter. The haystack carries the number with its “#” so both “#412”
    /// and “412” hit.
    /// </summary>
    public static bool Matches(GhItem item, IReadOnlyList<string> terms)
    {
        var hay = $"{item.Repo} #{item.Number} {item.Title}";
        if (item.IsPR)
        {
            hay += " pr";
            if (item.IsDraft) hay += " draft";
            if (item.IsReview) hay += " review";
        }
        foreach (var l in item.Labels) hay += " " + l.Name;
        hay = hay.ToLowerInvariant();
        // Ordinal, not culture-sensitive: word sort gives hyphens and apostrophes almost
        // no weight, so “email” would hit “e-mail”, and a term made only of ignorable
        // characters would match every row. Both sides are already lowercased.
        return terms.All(t => hay.Contains(t, StringComparison.Ordinal));
    }

    public static IReadOnlyList<string> Terms(string filter) =>
        filter.ToLowerInvariant().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);

    /// <summary>
    /// “3 assigned”, “3 assigned, 2 to review”, or just “2 to review” when that is all
    /// there is. The first group mixes issues and assigned PRs, so it is counted as
    /// “assigned” rather than given a noun that would be wrong for half of it.
    /// </summary>
    public static IReadOnlyList<CountPart> CountParts(int own, int reviews)
    {
        var parts = new List<CountPart>();
        if (own > 0 || reviews == 0) parts.Add(new CountPart(KindFilter.Own, $"{own} assigned"));
        if (reviews > 0) parts.Add(new CountPart(KindFilter.Review, $"{reviews} to review"));
        return parts;
    }

    /// <summary>Text on a GitHub label: dark on light colours, white otherwise.</summary>
    public static bool NeedsDarkText(byte r, byte g, byte b) => (0.299 * r + 0.587 * g + 0.114 * b) / 255.0 > 0.6;

    public static bool TryParseHex(string? hex, out byte r, out byte g, out byte b)
    {
        r = g = b = 0;
        if (string.IsNullOrEmpty(hex)) return false;
        var s = hex.TrimStart('#');
        if (s.Length != 6 || !int.TryParse(s, System.Globalization.NumberStyles.HexNumber, null, out var rgb)) return false;
        r = (byte)(rgb >> 16);
        g = (byte)(rgb >> 8);
        b = (byte)rgb;
        return true;
    }
}
