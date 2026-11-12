using System.ComponentModel;
using IssuesTray.Issues;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;

namespace IssuesTray;

/// <summary>A label in its real GitHub colour.</summary>
public sealed class LabelChip
{
    internal LabelChip(GhLabel label)
    {
        Name = label.Name;
        if (Fmt.TryParseHex(label.Color, out var r, out var g, out var b))
        {
            Background = new SolidColorBrush(ColorHelper.FromArgb(255, r, g, b));
            Foreground = new SolidColorBrush(Fmt.NeedsDarkText(r, g, b) ? ColorHelper.FromArgb(255, 20, 20, 20) : Colors.White);
        }
        else
        {
            Background = IssueItem.Theme("ControlFillColorSecondaryBrush");
            Foreground = IssueItem.Theme("TextFillColorPrimaryBrush");
        }
    }

    public string Name { get; }
    public Brush Background { get; }
    public Brush Foreground { get; }
}

/// <summary>One row of the popup. Only the age depends on the clock; Tick raises it
/// alone, so the list never has to be rebuilt (and lose its selection) to keep it
/// current.</summary>
public sealed class IssueItem : INotifyPropertyChanged
{
    private static readonly Brush Purple = new SolidColorBrush(ColorHelper.FromArgb(255, 0xA3, 0x71, 0xF7));
    private static readonly Brush Amber = new SolidColorBrush(ColorHelper.FromArgb(255, 0xD2, 0x99, 0x22));

    private DateTimeOffset _now;

    internal IssueItem(GhItem item, DateTimeOffset now, bool showLabels)
    {
        Item = item;
        _now = now;
        Labels = showLabels ? item.Labels.Select(l => new LabelChip(l)).ToList() : [];
    }

    internal GhItem Item { get; }

    public event PropertyChangedEventHandler? PropertyChanged;

    internal void Tick(DateTimeOffset now)
    {
        _now = now;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Age)));
    }

    public string RepoText => $"{Item.Repo} #{Item.Number}";
    public string Title => Item.Title;
    public string Age => Fmt.Age(Item.Updated, _now);
    public string Url => Item.Url;

    public Brush RepoBrush => Fmt.TryParseHex(Fmt.RepoColor(Item.Repo), out var r, out var g, out var b)
        ? new SolidColorBrush(ColorHelper.FromArgb(255, r, g, b))
        : Theme("AccentFillColorDefaultBrush");

    /// <summary>A review request trumps the plain PR marker: it is the reason the row is
    /// here (or, for a PR assigned to you as well, the more urgent of the two).</summary>
    public string ChipText => !Item.IsPR ? ""
        : Item.IsReview ? (Item.IsDraft ? "Draft review" : "Review")
        : Item.IsDraft ? "Draft PR" : "PR";

    public Brush ChipBrush => Item.IsDraft ? Theme("TextFillColorSecondaryBrush") : Item.IsReview ? Amber : Purple;

    public Visibility ChipVisibility => Item.IsPR ? Visibility.Visible : Visibility.Collapsed;

    public IReadOnlyList<LabelChip> Labels { get; }

    public Visibility LabelsVisibility => Labels.Count > 0 ? Visibility.Visible : Visibility.Collapsed;

    internal static Brush Theme(string key) =>
        Application.Current.Resources.TryGetValue(key, out var value) && value is Brush b
            ? b
            : new SolidColorBrush(Colors.Gray);
}
