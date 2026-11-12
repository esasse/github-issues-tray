using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Foundation;

namespace IssuesTray;

/// <summary>
/// Lays label chips out on one line and drops the ones that do not fit whole. A
/// plain horizontal StackPanel would clip the last chip in half, which reads as a
/// different label.
/// </summary>
public sealed partial class ChipPanel : Panel
{
    public double Spacing { get; set; } = 5;

    protected override Size MeasureOverride(Size available)
    {
        double x = 0, h = 0;
        foreach (var child in Children)
        {
            child.Measure(new Size(double.PositiveInfinity, available.Height));
            var w = child.DesiredSize.Width;
            var next = x == 0 ? w : x + Spacing + w;
            if (next > available.Width) break;
            x = next;
            h = Math.Max(h, child.DesiredSize.Height);
        }
        return new Size(x, h);
    }

    protected override Size ArrangeOverride(Size final)
    {
        double x = 0;
        var full = false;
        foreach (var child in Children)
        {
            var w = child.DesiredSize.Width;
            var start = x == 0 ? 0 : x + Spacing;
            if (full || start + w > final.Width)
            {
                // Arranged to nothing, which clips it away entirely.
                full = true;
                child.Arrange(new Rect(0, 0, 0, 0));
                continue;
            }
            child.Arrange(new Rect(start, 0, w, final.Height));
            x = start + w;
        }
        return final;
    }
}
