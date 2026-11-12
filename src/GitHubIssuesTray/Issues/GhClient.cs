using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace IssuesTray.Issues;

internal sealed record FetchResult(IReadOnlyList<GhItem> Items, IReadOnlyList<string> Errors);

/// <summary>
/// Talks to GitHub through the GitHub CLI: no token of our own, the app lives off
/// the credentials already in <c>gh auth status</c>.
/// </summary>
internal static class GhClient
{
    private const string Fields = "number,title,url,repository,labels,createdAt,updatedAt";

    /// <summary>gh.exe on the PATH, or where its installer puts it (an app started
    /// from the Startup folder gets Explorer's PATH, which may predate the install).</summary>
    public static string? Find()
    {
        var dirs = (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries);
        var fallback = new[]
        {
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "GitHub CLI"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "GitHub CLI"),
        };
        foreach (var dir in dirs.Concat(fallback))
        {
            try
            {
                var candidate = Path.Combine(dir.Trim('"'), "gh.exe");
                if (File.Exists(candidate)) return candidate;
            }
            catch (ArgumentException)
            {
                // a malformed PATH entry
            }
        }
        return null;
    }

    /// <summary>
    /// One query per kind, all at once. Any failure fails the whole fetch: a list
    /// missing the PRs would show a count that looks true and is not, so the caller
    /// keeps the last good list instead.
    /// </summary>
    public static async Task<FetchResult> FetchAsync(string gh, int limit, bool includeReviews, CancellationToken ct)
    {
        var queries = new List<(string Kind, string Args)>
        {
            ("issue", $"search issues --assignee @me --state open --sort updated --order desc --limit {limit} --json {Fields}"),
            ("pr", $"search prs --assignee @me --state open --sort updated --order desc --limit {limit} --json {Fields},isDraft"),
        };
        // review-requested also matches requests made to a team you are on, like
        // github.com/pulls/review-requested does, and a PR drops out on its own once
        // you submit your review.
        if (includeReviews)
            queries.Add(("review", $"search prs --review-requested @me --state open --sort updated --order desc --limit {limit} --json {Fields},isDraft"));

        var runs = await Task.WhenAll(queries.Select(q => RunAsync(gh, q.Args, ct)));

        var errors = new List<string>();
        var collected = new List<GhItem>();
        for (var i = 0; i < runs.Length; i++)
        {
            var (code, stdout, stderr) = runs[i];
            if (code != 0)
            {
                errors.Add(string.IsNullOrWhiteSpace(stderr) ? $"gh exited with code {code}" : Log.OneLine(stderr));
                continue;
            }
            if (string.IsNullOrWhiteSpace(stdout)) continue;
            try
            {
                collected.AddRange(Parse(stdout, queries[i].Kind));
            }
            catch (Exception ex) when (ex is JsonException or InvalidOperationException or FormatException)
            {
                errors.Add($"invalid response from gh: {Log.OneLine(ex.Message)}");
            }
        }

        // Every query fails with the same message when the network is down; saying it
        // more than once helps nobody.
        if (errors.Count > 0) return new FetchResult([], errors.Distinct().ToList());

        // A PR assigned to you that also asks for your review comes back from two
        // queries. Listed twice it would count twice in the tray; kept once, it
        // carries both reasons.
        var byUrl = new Dictionary<string, GhItem>();
        var ordered = new List<GhItem>();
        foreach (var item in collected)
        {
            if (byUrl.TryGetValue(item.Url, out var seen))
            {
                seen.IsAssigned |= item.IsAssigned;
                seen.IsReview |= item.IsReview;
            }
            else
            {
                byUrl[item.Url] = item;
                ordered.Add(item);
            }
        }
        return new FetchResult(ordered, []);
    }

    private static IEnumerable<GhItem> Parse(string json, string kind)
    {
        using var doc = JsonDocument.Parse(json);
        var list = new List<GhItem>();
        foreach (var e in doc.RootElement.EnumerateArray())
        {
            var labels = new List<GhLabel>();
            if (e.TryGetProperty("labels", out var ls) && ls.ValueKind == JsonValueKind.Array)
                foreach (var l in ls.EnumerateArray())
                    labels.Add(new GhLabel(Str(l, "name"), Str(l, "color")));

            var repo = e.TryGetProperty("repository", out var r) && r.ValueKind == JsonValueKind.Object ? Str(r, "nameWithOwner") : "";
            list.Add(new GhItem
            {
                Number = e.GetProperty("number").GetInt32(),
                Title = Str(e, "title"),
                Url = Str(e, "url"),
                Repo = repo,
                IsPR = kind != "issue",
                IsDraft = e.TryGetProperty("isDraft", out var d) && d.ValueKind == JsonValueKind.True,
                IsAssigned = kind != "review",
                IsReview = kind == "review",
                Created = e.GetProperty("createdAt").GetDateTimeOffset(),
                Updated = e.GetProperty("updatedAt").GetDateTimeOffset(),
                Labels = labels,
            });
        }
        return list;
    }

    private static string Str(JsonElement e, string name) =>
        e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? "" : "";

    /// <summary>
    /// Runs gh hidden and drains both pipes concurrently (a full stderr pipe would
    /// otherwise hang a child that is still writing stdout). On cancellation the
    /// child is killed, so a gh stuck on a half-open connection does not linger.
    /// </summary>
    private static async Task<(int Code, string Out, string Err)> RunAsync(string gh, string args, CancellationToken ct)
    {
        var psi = new ProcessStartInfo(gh, args)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        // See TelemetryOff: CreateNoWindow does not reach gh's own children.
        psi.Environment["GH_TELEMETRY"] = "0";

        using var proc = Process.Start(psi) ?? throw new InvalidOperationException("could not start gh");
        var stdout = proc.StandardOutput.ReadToEndAsync(ct);
        var stderr = proc.StandardError.ReadToEndAsync(ct);
        try
        {
            await proc.WaitForExitAsync(ct);
            return (proc.ExitCode, await stdout, await stderr);
        }
        catch (OperationCanceledException)
        {
            try { proc.Kill(entireProcessTree: true); } catch { /* already gone */ }
            throw;
        }
    }

    /// <summary>
    /// Since gh 2.92 a command sometimes hands its telemetry to a detached gh child,
    /// and that child runs tzutil.exe. With no console to inherit, tzutil gets one of
    /// its own, and with Windows Terminal as the default terminal that is a window
    /// flashing on screen every so often. Set on this process too, so `gh auth login`
    /// inherits it.
    /// </summary>
    public static void TelemetryOff() => Environment.SetEnvironmentVariable("GH_TELEMETRY", "0");
}
