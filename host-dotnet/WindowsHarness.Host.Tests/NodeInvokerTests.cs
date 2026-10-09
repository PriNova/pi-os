using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using WindowsHarness.Contracts;
using WindowsHarness.Host.Http;

namespace WindowsHarness.Host.Tests;

public sealed class NodeInvokerTests
{
    private sealed class FixtureHandler(Func<HttpRequestMessage, Task<HttpResponseMessage>> respond) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) => respond(request);
    }

    [Fact]
    public async Task WindowsReaderExplicitlyRetainsItsThreadAndAuthenticatesBothTurns()
    {
        var paths = new List<string>();
        string? invocationId = null;
        using var handler = new FixtureHandler(async request =>
        {
            paths.Add(request.RequestUri!.AbsolutePath);
            Assert.Equal("fixture-token", request.Headers.GetValues("X-Harness-Token").Single());
            using var body = JsonDocument.Parse(await request.Content!.ReadAsStringAsync());
            if (paths.Count == 1)
            {
                Assert.True(body.RootElement.GetProperty("retainSession").GetBoolean());
                Assert.True(body.RootElement.GetProperty("includeScreenshot").GetBoolean());
                Assert.Equal("ctx-fixture", body.RootElement.GetProperty("contextId").GetString());
                invocationId = body.RootElement.GetProperty("invocationId").GetString();
                return new HttpResponseMessage(HttpStatusCode.Accepted);
            }
            Assert.Equal("Second question", body.RootElement.GetProperty("prompt").GetString());
            return new HttpResponseMessage(HttpStatusCode.Accepted);
        });
        using var client = new HttpClient(handler) { BaseAddress = new Uri("http://fixture.invalid") };
        var invoker = new NodeInvoker("fixture-token", client);
        var snapshot = new DesktopContextSnapshot { Id = "ctx-fixture", CapturedAt = DateTimeOffset.UtcNow, Cursor = new Point2D { X = 0, Y = 0 } };
        var id = await invoker.SendInvocationAsync(snapshot, "First question");
        Assert.NotNull(id); Assert.Equal(invocationId, id);
        Assert.True(await invoker.SendFollowupAsync(id!, "Second question"));
        Assert.Equal(new[] { "/invoke", $"/invocations/{id}/followup" }, paths);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task InitialScreenshotChoiceIsSentWithInvocation(bool includeScreenshot)
    {
        using var handler = new FixtureHandler(async request =>
        {
            using var body = JsonDocument.Parse(await request.Content!.ReadAsStringAsync());
            Assert.Equal(includeScreenshot, body.RootElement.GetProperty("includeScreenshot").GetBoolean());
            return new HttpResponseMessage(HttpStatusCode.Accepted);
        });
        using var client = new HttpClient(handler) { BaseAddress = new Uri("http://fixture.invalid") };
        var snapshot = new DesktopContextSnapshot { Id = "ctx-fixture", CapturedAt = DateTimeOffset.UtcNow, Cursor = new Point2D { X = 0, Y = 0 } };
        Assert.NotNull(await new NodeInvoker("fixture-token", client).SendInvocationAsync(snapshot, "Question", includeScreenshot));
    }

    [Theory]
    [InlineData("true", true)]
    [InlineData("false", false)]
    [InlineData("null", false)]
    public async Task TerminalStatusReportsWhetherFollowupAuthoritySurvives(string available, bool expected)
    {
        using var handler = new FixtureHandler(_ => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent($"{{\"state\":\"completed\",\"followupAvailable\":{available}}}", Encoding.UTF8, "application/json"),
        }));
        using var client = new HttpClient(handler) { BaseAddress = new Uri("http://fixture.invalid") };
        var status = await new NodeInvoker("fixture-token", client).PollUntilTerminalAsync("inv-fixture", onUpdate: null);
        Assert.True(status.IsTerminal);
        Assert.Equal(expected, status.FollowupAvailable);
    }
}
