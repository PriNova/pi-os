using System.ComponentModel;
using System.Diagnostics;
using System.Windows;
using System.Windows.Documents;
using System.Windows.Media;
using Markdig;
using Markdig.Extensions.Tables;
using Markdig.Extensions.EmphasisExtras;
using Markdig.Syntax;
using Markdig.Syntax.Inlines;
using WindowsHarness.Host.Diagnostics;
using WpfTable = System.Windows.Documents.Table;
using MarkdownTable = Markdig.Extensions.Tables.Table;
using MarkdownList = Markdig.Syntax.ListBlock;

namespace WindowsHarness.Host.Overlay;

/// <summary>Renders reply Markdown as selectable native text. No HTML or image loading.</summary>
internal static class MarkdownDocumentRenderer
{
    private static readonly MarkdownPipeline Pipeline = new MarkdownPipelineBuilder()
        .DisableHtml()
        .UsePipeTables(new PipeTableOptions { UseGfmRules = true })
        .UseEmphasisExtras(EmphasisExtraOptions.Strikethrough)
        .UseAutoLinks()
        .Build();
    private static readonly Brush CodeBackground = FrozenBrush(0x25, 0x25, 0x29);
    private static readonly Brush LinkForeground = FrozenBrush(0x7D, 0xCE, 0xFF);
    private static readonly Brush MutedForeground = FrozenBrush(0xAE, 0xAE, 0xB5);
    private static readonly FontFamily CodeFont = new("Consolas");

    private static Brush FrozenBrush(byte red, byte green, byte blue)
    {
        var brush = new SolidColorBrush(Color.FromRgb(red, green, blue));
        brush.Freeze();
        return brush;
    }

    internal static FlowDocument Render(string text, bool markdown = true)
    {
        var document = new FlowDocument
        {
            FontFamily = new FontFamily("Segoe UI"),
            FontSize = 13,
            Foreground = new SolidColorBrush(Color.FromRgb(0xEA, 0xEA, 0xEA)),
            PagePadding = new Thickness(0),
        };
        if (markdown)
            AddBlocks(document.Blocks, Markdown.Parse(text, Pipeline));
        else
            document.Blocks.Add(new Paragraph(new Run(text)) { Margin = new Thickness(0) });
        return document;
    }

    private static void AddBlocks(BlockCollection target, ContainerBlock source)
    {
        foreach (var block in source)
        {
            switch (block)
            {
                case HeadingBlock heading:
                    var title = Paragraph(heading);
                    title.FontSize = heading.Level switch { 1 => 22, 2 => 19, 3 => 16, _ => 14 };
                    title.FontWeight = FontWeights.SemiBold;
                    title.Margin = new Thickness(0, 8, 0, 6);
                    target.Add(title);
                    break;
                case ParagraphBlock paragraph:
                    target.Add(Paragraph(paragraph));
                    break;
                case CodeBlock code:
                    target.Add(new Paragraph(new Run(code.Lines.ToString()))
                    {
                        FontFamily = CodeFont,
                        Background = CodeBackground,
                        Padding = new Thickness(8),
                        Margin = new Thickness(0, 4, 0, 8),
                    });
                    break;
                case MarkdownList list:
                    var renderedList = new System.Windows.Documents.List
                    {
                        MarkerStyle = list.IsOrdered ? TextMarkerStyle.Decimal : TextMarkerStyle.Disc,
                        StartIndex = list.IsOrdered && int.TryParse(list.OrderedStart, out var start) && start > 0 ? start : 1,
                        Padding = new Thickness(22, 0, 0, 0),
                        Margin = new Thickness(0, 0, 0, 8),
                    };
                    foreach (var item in list.OfType<ListItemBlock>())
                    {
                        var renderedItem = new ListItem();
                        AddBlocks(renderedItem.Blocks, item);
                        renderedList.ListItems.Add(renderedItem);
                    }
                    target.Add(renderedList);
                    break;
                case QuoteBlock quote:
                    var section = new Section
                    {
                        BorderBrush = MutedForeground,
                        BorderThickness = new Thickness(3, 0, 0, 0),
                        Padding = new Thickness(10, 0, 0, 0),
                        Margin = new Thickness(0, 4, 0, 8),
                        Foreground = MutedForeground,
                    };
                    AddBlocks(section.Blocks, quote);
                    target.Add(section);
                    break;
                case ThematicBreakBlock:
                    target.Add(new Paragraph
                    {
                        BorderBrush = MutedForeground,
                        BorderThickness = new Thickness(0, 0, 0, 1),
                        FontSize = 1,
                        Margin = new Thickness(0, 4, 0, 8),
                    });
                    break;
                case MarkdownTable table:
                    target.Add(RenderTable(table));
                    break;
                case ContainerBlock container:
                    AddBlocks(target, container);
                    break;
                case LeafBlock leaf:
                    target.Add(Paragraph(leaf));
                    break;
            }
        }
    }

    private static Paragraph Paragraph(LeafBlock leaf)
    {
        var paragraph = new Paragraph { Margin = new Thickness(0, 0, 0, 8) };
        if (leaf.Inline is not null) AddInlines(paragraph.Inlines, leaf.Inline);
        else paragraph.Inlines.Add(new Run(leaf.Lines.ToString()));
        return paragraph;
    }

    private static WpfTable RenderTable(MarkdownTable source)
    {
        var table = new WpfTable { CellSpacing = 0, Margin = new Thickness(0, 4, 0, 8) };
        var group = new TableRowGroup();
        table.RowGroups.Add(group);
        foreach (var row in source.OfType<Markdig.Extensions.Tables.TableRow>())
        {
            var renderedRow = new System.Windows.Documents.TableRow();
            group.Rows.Add(renderedRow);
            var columnIndex = 0;
            foreach (var cell in row.OfType<Markdig.Extensions.Tables.TableCell>())
            {
                var renderedCell = new System.Windows.Documents.TableCell
                {
                    BorderBrush = MutedForeground,
                    BorderThickness = new Thickness(0.5),
                    Padding = new Thickness(6),
                    FontWeight = row.IsHeader ? FontWeights.SemiBold : FontWeights.Normal,
                    Background = row.IsHeader ? CodeBackground : Brushes.Transparent,
                };
                AddBlocks(renderedCell.Blocks, cell);
                if (columnIndex < source.ColumnDefinitions.Count)
                {
                    renderedCell.TextAlignment = source.ColumnDefinitions[columnIndex].Alignment switch
                    {
                        TableColumnAlign.Center => TextAlignment.Center,
                        TableColumnAlign.Right => TextAlignment.Right,
                        _ => TextAlignment.Left,
                    };
                }
                renderedRow.Cells.Add(renderedCell);
                columnIndex++;
            }
        }
        return table;
    }

    private static void AddInlines(InlineCollection target, ContainerInline source)
    {
        foreach (var inline in source)
        {
            switch (inline)
            {
                case LiteralInline literal:
                    target.Add(new Run(literal.Content.ToString()));
                    break;
                case HtmlEntityInline entity:
                    target.Add(new Run(entity.Transcoded.ToString()));
                    break;
                case CodeInline code:
                    target.Add(new Run(code.Content) { FontFamily = CodeFont, Background = CodeBackground });
                    break;
                case LineBreakInline line:
                    if (line.IsHard) target.Add(new LineBreak());
                    else target.Add(new Run(" "));
                    break;
                case EmphasisInline emphasis:
                    var span = new Span();
                    if (emphasis.DelimiterChar == '~' && emphasis.DelimiterCount == 2)
                        span.TextDecorations = TextDecorations.Strikethrough;
                    else if (emphasis.DelimiterChar is '*' or '_')
                    {
                        if (emphasis.DelimiterCount >= 2) span.FontWeight = FontWeights.Bold;
                        else span.FontStyle = FontStyles.Italic;
                    }
                    AddInlines(span.Inlines, emphasis);
                    target.Add(span);
                    break;
                case LinkInline link:
                    // Image alt text remains readable. No URI is resolved or loaded.
                    if (link.IsImage || !TryGetWebUri(link.Url, out var uri))
                        AddInlines(target, link);
                    else
                    {
                        var hyperlink = CreateLink(uri!);
                        AddInlines(hyperlink.Inlines, link);
                        target.Add(hyperlink);
                    }
                    break;
                case AutolinkInline autoLink:
                    if (!autoLink.IsEmail && TryGetWebUri(autoLink.Url, out var autoUri))
                    {
                        var hyperlink = CreateLink(autoUri!);
                        hyperlink.Inlines.Add(new Run(autoLink.Url));
                        target.Add(hyperlink);
                    }
                    else target.Add(new Run(autoLink.Url));
                    break;
                case ContainerInline container:
                    AddInlines(target, container);
                    break;
            }
        }
    }

    internal static bool TryGetWebUri(string? value, out Uri? uri)
    {
        uri = null;
        if (!Uri.TryCreate(value, UriKind.Absolute, out var candidate)
            || candidate.Scheme is not ("https" or "http")
            || string.IsNullOrEmpty(candidate.Host)
            || !string.IsNullOrEmpty(candidate.UserInfo)) return false;
        uri = candidate;
        return true;
    }

    private static Hyperlink CreateLink(Uri uri)
    {
        var link = new Hyperlink { NavigateUri = uri, Foreground = LinkForeground, ToolTip = uri.AbsoluteUri };
        link.RequestNavigate += (_, e) =>
        {
            e.Handled = true;
            if (!TryGetWebUri(e.Uri.AbsoluteUri, out var destination)) return;
            try
            {
                Process.Start(new ProcessStartInfo(destination!.AbsoluteUri) { UseShellExecute = true });
            }
            catch (Exception ex) when (ex is Win32Exception or InvalidOperationException)
            {
                Log.Warn("Could not open the reply link in the default browser.");
            }
        };
        return link;
    }
}
