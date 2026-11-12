namespace IssuesTray.Issues;

internal sealed record GhLabel(string Name, string Color);

/// <summary>An issue or pull request, as it came from <c>gh search</c>.</summary>
internal sealed class GhItem
{
    public int Number { get; init; }
    public string Title { get; init; } = "";
    public string Url { get; init; } = "";
    /// <summary>owner/name</summary>
    public string Repo { get; init; } = "";
    public bool IsPR { get; init; }
    public bool IsDraft { get; init; }
    /// <summary>Came from an assignee query: an issue or a PR assigned to you.</summary>
    public bool IsAssigned { get; set; }
    /// <summary>Came from the review-requested query. A PR that is both is listed once,
    /// as a review: the more urgent of the two reasons.</summary>
    public bool IsReview { get; set; }
    public DateTimeOffset Created { get; init; }
    public DateTimeOffset Updated { get; init; }
    public IReadOnlyList<GhLabel> Labels { get; init; } = [];
}

/// <summary>Which of the assigned groups the list shows; a click on a count in the
/// header picks one.</summary>
internal enum KindFilter { None, Own, Review }

/// <summary>P lists only pull requests and I only issues. One switch with three
/// states, not two flags: both on would only ever be an empty list. It is kept apart
/// from <see cref="KindFilter"/> so the two compose (“assigned” then means the PRs
/// assigned to you) instead of one replacing the other.</summary>
internal enum TypeFilter { None, PR, Issue }
