using System.Runtime.ExceptionServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using WindowsHarness.Host.Overlay;

namespace WindowsHarness.Host.Tests;

public sealed class MarkdownDocumentRendererTests
{
    [Fact]
    public void RendersHeadingsEmphasisAndInlineCode() => OnSta(() =>
    {
        var document = MarkdownDocumentRenderer.Render("# Title\n\n**bold** and *italic* and `code` and ~~gone~~");
        var blocks = document.Blocks.Cast<Block>().ToArray();
        var heading = Assert.IsType<Paragraph>(blocks[0]);
        Assert.Equal(22, heading.FontSize);
        Assert.Equal(FontWeights.SemiBold, heading.FontWeight);
        var paragraph = Assert.IsType<Paragraph>(blocks[1]);
        var spans = paragraph.Inlines.OfType<Span>().ToArray();
        Assert.Equal(FontWeights.Bold, spans[0].FontWeight);
        Assert.Equal(FontStyles.Italic, spans[1].FontStyle);
        Assert.Equal(TextDecorations.Strikethrough, spans[2].TextDecorations);
        var code = Assert.Single(paragraph.Inlines.OfType<Run>(), run => run.Text == "code");
        Assert.Equal("Consolas", code.FontFamily.Source);
        Assert.Equal("Title\r\nbold and italic and code and gone\r\n", Text(document));
    });

    [Fact]
    public void RendersNestedListsQuotesAndOrderedStart() => OnSta(() =>
    {
        var document = MarkdownDocumentRenderer.Render("3. third\n   - nested\n4. fourth\n\n> quoted");
        var list = Assert.IsType<System.Windows.Documents.List>(document.Blocks.FirstBlock);
        Assert.Equal(3, list.StartIndex);
        Assert.Equal(TextMarkerStyle.Decimal, list.MarkerStyle);
        Assert.Equal(2, list.ListItems.Count);
        var nested = Assert.IsType<System.Windows.Documents.List>(list.ListItems.FirstListItem.Blocks.LastBlock);
        Assert.Equal(TextMarkerStyle.Disc, nested.MarkerStyle);
        Assert.IsType<Section>(document.Blocks.LastBlock);
        Assert.Contains("quoted", Text(document));
    });

    [Fact]
    public void PreservesCodeAndHardLineBreaks() => OnSta(() =>
    {
        var document = MarkdownDocumentRenderer.Render("first  \nsecond\n\n```cs\nvar x = \"<tag>\";\n  // **literal**\n```");
        var paragraph = Assert.IsType<Paragraph>(document.Blocks.FirstBlock);
        Assert.Single(paragraph.Inlines.OfType<LineBreak>());
        var code = Assert.IsType<Paragraph>(document.Blocks.LastBlock);
        Assert.Equal("Consolas", code.FontFamily.Source);
        Assert.Equal("var x = \"<tag>\";\n  // **literal**", Assert.IsType<Run>(code.Inlines.FirstInline).Text);
    });

    [Fact]
    public void RendersPipeTablesWithHeaderAndAlignment() => OnSta(() =>
    {
        var document = MarkdownDocumentRenderer.Render("| Name | Value |\n| :--- | ---: |\n| item | **42** |");
        var table = Assert.IsType<Table>(document.Blocks.FirstBlock);
        var group = Assert.Single(table.RowGroups.Cast<TableRowGroup>());
        Assert.Equal(2, group.Rows.Count);
        var header = group.Rows[0];
        Assert.Equal(FontWeights.SemiBold, header.Cells[0].FontWeight);
        Assert.Equal(TextAlignment.Right, header.Cells[1].TextAlignment);
        Assert.Contains("42", Text(document));
    });

    [Fact]
    public void OnlyWebLinksBecomeHyperlinksAndImagesStayText() => OnSta(() =>
    {
        var document = MarkdownDocumentRenderer.Render(
            "[safe](https://example.com/page) [local](file:///C:/dummy) [script](javascript:alert) " +
            "![image description](https://example.com/image.png) https://example.org");
        var paragraph = Assert.IsType<Paragraph>(document.Blocks.FirstBlock);
        var links = paragraph.Inlines.OfType<Hyperlink>().ToArray();
        Assert.Equal(2, links.Length);
        Assert.All(links, link => Assert.Equal("https", link.NavigateUri.Scheme));
        Assert.Contains("image description", Text(document));
        Assert.Empty(paragraph.Inlines.OfType<InlineUIContainer>());
    });

    [Theory]
    [InlineData("https://example.com", true)]
    [InlineData("http://example.com/path?q=1", true)]
    [InlineData("file:///C:/dummy", false)]
    [InlineData("javascript:alert(1)", false)]
    [InlineData("data:text/html,test", false)]
    [InlineData("mailto:dummy@example.com", false)]
    [InlineData("/relative", false)]
    [InlineData("https://dummy:dummy@example.com", false)]
    public void ValidatesNavigationUris(string value, bool allowed)
    {
        Assert.Equal(allowed, MarkdownDocumentRenderer.TryGetWebUri(value, out var uri));
        Assert.Equal(allowed, uri is not null);
    }

    [Fact]
    public void HtmlIsLiteralAndFailuresCanBypassMarkdown() => OnSta(() =>
    {
        const string html = "<script>alert('dummy')</script>\n<img src=\"https://example.com/dummy\">";
        Assert.Contains("<script>", Text(MarkdownDocumentRenderer.Render(html)));
        Assert.Contains("<img", Text(MarkdownDocumentRenderer.Render(html)));
        const string failure = "# Failure\n**literal** C:\\dummy\\path";
        var document = MarkdownDocumentRenderer.Render(failure, markdown: false);
        var paragraph = Assert.IsType<Paragraph>(document.Blocks.FirstBlock);
        Assert.Equal(failure, Assert.IsType<Run>(paragraph.Inlines.FirstInline).Text);
    });

    [Fact]
    public void PreservesEntitiesEscapesAndReferenceLinks() => OnSta(() =>
    {
        var document = MarkdownDocumentRenderer.Render(
            "A &amp; B &#60; C \\*literal\\* ==unchanged== [reference][site]\n\n[site]: https://example.com");
        Assert.Contains("A & B < C *literal* ==unchanged== reference", Text(document));
        var paragraph = Assert.IsType<Paragraph>(document.Blocks.FirstBlock);
        Assert.Equal("https://example.com/", Assert.Single(paragraph.Inlines.OfType<Hyperlink>()).NavigateUri.AbsoluteUri);
    });

    [Fact]
    public void LongAndEmptyRepliesRemainSelectableInReadOnlyReader() => OnSta(() =>
    {
        var empty = MarkdownDocumentRenderer.Render("");
        Assert.Empty(empty.Blocks.Cast<Block>());
        var markdown = string.Join("\n\n", Enumerable.Repeat("**selectable** text", 500));
        var reader = new RichTextBox
        {
            IsReadOnly = true,
            IsDocumentEnabled = true,
            Document = MarkdownDocumentRenderer.Render(markdown),
        };
        Assert.Equal(500, reader.Document.Blocks.Count);
        reader.SelectAll();
        Assert.Equal(Text(reader.Document), reader.Selection.Text);
        var previous = reader.Selection.Text;
        reader.Document = MarkdownDocumentRenderer.Render("new answer");
        reader.Document = MarkdownDocumentRenderer.Render(markdown);
        reader.SelectAll();
        Assert.Equal(previous, reader.Selection.Text);
    });

    private static string Text(FlowDocument document) => new TextRange(document.ContentStart, document.ContentEnd).Text;

    // Native document objects need STA. No visible desktop or clipboard is used.
    private static void OnSta(Action action)
    {
        Exception? failure = null;
        var thread = new Thread(() =>
        {
            try { action(); }
            catch (Exception ex) { failure = ex; }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join();
        if (failure is not null) ExceptionDispatchInfo.Capture(failure).Throw();
    }
}
