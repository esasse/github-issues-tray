using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;

namespace IssuesTray;

internal enum TrayMode
{
    /// <summary>Accent disc with the count.</summary>
    Normal,
    /// <summary>Grey disc with 0: genuinely nothing assigned.</summary>
    Zero,
    /// <summary>Grey disc with the count: the refresh failed, but the cached list is
    /// still worth showing, so the number stays instead of being thrown away.</summary>
    Stale,
    /// <summary>Red disc with "!": nothing to show and something is wrong.</summary>
    Error,
    /// <summary>Grey disc with three dots: before the first query comes back, when 0
    /// would claim an inbox is clear that may not be.</summary>
    Loading,
}

/// <summary>Draws the tray icon at runtime, with the count inside it.</summary>
internal static class TrayIconRenderer
{
    private static readonly Color Grey = Color.FromArgb(255, 0x6E, 0x76, 0x81);
    private static readonly Color Red = Color.FromArgb(255, 0xE5, 0x53, 0x4B);

    /// <summary>Exactly the size the notification area asks for: a larger icon would
    /// arrive resampled by the shell and come out soft.</summary>
    public static int IconSize()
    {
        // The primary display's DPI now, not GetDpiForSystem: that one is frozen at
        // sign-in, and after a scale change the icon would be drawn at the old size.
        var dpi = (uint)Math.Round(Native.ScaleAt(0, 0) * 96);
        var size = Native.GetSystemMetricsForDpi(Native.SM_CXSMICON, dpi);
        return size < 16 ? 16 : size;
    }

    private static readonly Color DefaultAccent = Color.FromArgb(255, 0x00, 0xA8, 0xFF);

    /// <summary>ColorTranslator, as the PowerShell version read it: "#0AF" and "orange"
    /// are colours too, not a silent fall back to the default blue.</summary>
    public static Color ParseAccent(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return DefaultAccent;
        try
        {
            var c = ColorTranslator.FromHtml(value.Trim());
            if (!c.IsEmpty) return Color.FromArgb(255, c.R, c.G, c.B);
        }
        catch (Exception)
        {
            // not a colour
        }
        return DefaultAccent;
    }

    /// <summary>Returns an HICON the caller owns (DestroyIcon).</summary>
    public static IntPtr Render(TrayMode mode, int count, int size, Color accent)
    {
        var fill = mode switch
        {
            TrayMode.Normal => accent,
            TrayMode.Error => Red,
            _ => Grey,
        };
        var text = mode switch
        {
            TrayMode.Error => "!",
            TrayMode.Zero => "0",
            TrayMode.Loading => "",
            _ => count > 99 ? "99+" : count.ToString(),
        };
        var fg = Issues.Fmt.NeedsDarkText(fill.R, fill.G, fill.B) ? Color.FromArgb(255, 20, 20, 20) : Color.White;

        using var bmp = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
            g.Clear(Color.Transparent);

            using (var brush = new SolidBrush(fill))
                g.FillEllipse(brush, 0.5f, 0.5f, size - 1f, size - 1f);

            if (mode == TrayMode.Loading) DrawDots(g, size, fg);
            else DrawText(g, text, fg, TextBox(size, text.Length));
        }
        return bmp.GetHicon();
    }

    /// <summary>A circle is only as wide as the icon across its middle, and narrower
    /// over the band the glyphs occupy: the longer the text, the wider and lower the
    /// box, so "99+" clears the edge and "7" is not a speck.</summary>
    private static RectangleF TextBox(int size, int length)
    {
        float s = size;
        var (w, h) = length switch
        {
            1 => (0.40f, 0.52f),
            2 => (0.62f, 0.46f),
            _ => (0.74f, 0.36f),
        };
        return new RectangleF(s * (1 - w) / 2, s * (1 - h) / 2, s * w, s * h);
    }

    /// <summary>Three dots drawn by hand rather than the "…" glyph, whose ink sits at
    /// the bottom of its line box and would land on the floor of the circle.</summary>
    private static void DrawDots(Graphics g, int size, Color color)
    {
        using var brush = new SolidBrush(color);
        var r = Math.Max(1f, size * 0.075f);
        var gap = r * 3.2f;
        var c = size / 2f;
        foreach (var off in new[] { -gap, 0f, gap })
            g.FillEllipse(brush, c + off - r, c - r, r * 2, r * 2);
    }

    /// <summary>
    /// Text as a filled path, scaled to the box and centred on its ink, not on the
    /// font's line box: at 20 px a line box puts a "12" visibly low.
    /// </summary>
    private static void DrawText(Graphics g, string text, Color color, RectangleF box)
    {
        if (string.IsNullOrEmpty(text) || box.Width <= 0 || box.Height <= 0) return;
        using var family = new FontFamily("Segoe UI");
        using var path = new GraphicsPath();
        path.AddString(text, family, (int)FontStyle.Bold, 100f, PointF.Empty, StringFormat.GenericTypographic);
        var ink = path.GetBounds();
        if (ink.Width <= 0 || ink.Height <= 0) return;

        var scale = Math.Min(box.Width / ink.Width, box.Height / ink.Height);
        using var m = new Matrix();
        m.Translate(box.X + (box.Width - ink.Width * scale) / 2, box.Y + (box.Height - ink.Height * scale) / 2);
        m.Scale(scale, scale);
        m.Translate(-ink.X, -ink.Y);
        path.Transform(m);
        using var brush = new SolidBrush(color);
        g.FillPath(brush, path);
    }
}
