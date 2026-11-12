using System.Text.Json;
using System.Text.Json.Nodes;

namespace IssuesTray.Issues;

/// <summary>
/// cache.json and prefs.json, in the format the PowerShell version wrote, so an
/// upgrade starts with the list already populated and the order (O) remembered.
/// </summary>
internal static class Store
{
    private static readonly JsonSerializerOptions Indented = new() { WriteIndented = true };

    public static void SaveCache(IReadOnlyList<GhItem> items, DateTimeOffset savedAt)
    {
        try
        {
            var array = new JsonArray();
            foreach (var i in items)
            {
                var labels = new JsonArray();
                foreach (var l in i.Labels) labels.Add(new JsonObject { ["name"] = l.Name, ["color"] = l.Color });
                array.Add(new JsonObject
                {
                    ["number"] = i.Number, ["title"] = i.Title, ["url"] = i.Url, ["repo"] = i.Repo,
                    ["isPR"] = i.IsPR, ["isDraft"] = i.IsDraft,
                    ["isAssigned"] = i.IsAssigned, ["isReview"] = i.IsReview,
                    ["updated"] = i.Updated.ToString("o"), ["created"] = i.Created.ToString("o"),
                    ["labels"] = labels,
                });
            }
            var root = new JsonObject { ["savedAt"] = savedAt.ToString("o"), ["items"] = array };
            File.WriteAllText(AppPaths.CacheFile, root.ToJsonString(Indented));
        }
        catch (Exception ex)
        {
            Log.Write($"failed to write cache: {ex.Message}");
        }
    }

    public static (List<GhItem> Items, DateTimeOffset? SavedAt) LoadCache(bool includeReviews)
    {
        var items = new List<GhItem>();
        if (!File.Exists(AppPaths.CacheFile)) return (items, null);
        try
        {
            var root = JsonNode.Parse(File.ReadAllText(AppPaths.CacheFile))!.AsObject();
            foreach (var node in Many(root["items"]))
            {
                if (node is not JsonObject o) continue;
                var labels = Many(o["labels"]).OfType<JsonObject>()
                    .Select(l => new GhLabel(Text(l["name"]), Text(l["color"]))).ToList();
                items.Add(new GhItem
                {
                    Number = (int?)o["number"] ?? 0,
                    Title = Text(o["title"]),
                    Url = Text(o["url"]),
                    Repo = Text(o["repo"]),
                    IsPR = Flag(o["isPR"]),
                    IsDraft = Flag(o["isDraft"]),
                    // A cache written before review requests existed has no isAssigned,
                    // and every item in it came from an assignee query.
                    IsAssigned = o["isAssigned"] == null || Flag(o["isAssigned"]),
                    // A cache written while review requests were on still says isReview
                    // after they are turned off; left as is, an assigned PR would show the
                    // Review chip until the first fetch lands.
                    IsReview = includeReviews && Flag(o["isReview"]),
                    Updated = Date(o["updated"]),
                    Created = Date(o["created"]),
                    Labels = labels,
                });
            }
            DateTimeOffset? savedAt = root["savedAt"] is { } s && DateTimeOffset.TryParse(Text(s), out var at) ? at : null;
            Log.Write($"cache restored: {items.Count} items");
            return (items, savedAt);
        }
        catch (Exception ex)
        {
            Log.Write($"failed to read cache: {ex.Message}");
            return ([], null);
        }
    }

    public static bool LoadOldestFirst()
    {
        try
        {
            if (!File.Exists(AppPaths.PrefsFile)) return false;
            var root = JsonNode.Parse(File.ReadAllText(AppPaths.PrefsFile));
            return Text(root?["order"]) == "oldest";
        }
        catch (Exception ex)
        {
            Log.Write($"failed to read prefs: {Log.OneLine(ex.Message)}");
            return false;
        }
    }

    public static void SaveOldestFirst(bool oldestFirst)
    {
        try
        {
            var root = new JsonObject { ["order"] = oldestFirst ? "oldest" : "newest" };
            File.WriteAllText(AppPaths.PrefsFile, root.ToJsonString(Indented));
        }
        catch (Exception ex)
        {
            Log.Write($"failed to write prefs: {Log.OneLine(ex.Message)}");
        }
    }

    /// <summary>PowerShell 5.1's ConvertTo-Json writes a one-element array as the
    /// element itself, so a list in an old cache may arrive as a bare object.</summary>
    private static IEnumerable<JsonNode?> Many(JsonNode? node) => node switch
    {
        JsonArray a => a,
        JsonObject o => [o],
        _ => [],
    };

    private static string Text(JsonNode? node) =>
        node is JsonValue v && v.TryGetValue<string>(out var s) ? s : node?.ToString() ?? "";

    private static bool Flag(JsonNode? node) => node is JsonValue v && v.TryGetValue<bool>(out var b) && b;

    private static DateTimeOffset Date(JsonNode? node) =>
        DateTimeOffset.TryParse(Text(node), out var d) ? d : DateTimeOffset.MinValue;
}
