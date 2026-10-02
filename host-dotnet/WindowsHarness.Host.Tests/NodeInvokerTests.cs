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
        using var handler = new FixtureHandler(async request =>
        {
            paths.Add(request.RequestUri!.AbsolutePath);
            Assert.Equal("fixture-token", request.Headers.GetValues("X-Harness-Token").Single());
            using var body = JsonDocument.Parse(await request.Content!.ReadAsStringAsync());
            if (paths.Count == 1)
            {
                Assert.True(body.RootElement.GetProperty("retainSession").GetBoolean());
                Assert.Equal("ctx-fixture", body.RootElement.GetProperty("contextId").GetString());
                return new HttpResponseMessage(HttpStatusCode.Accepted)
                {
                    Content = new StringContent("{\"invocationId\":\"inv-fixture\"}", Encoding.UTF8, "application/json"),
                };
            }
            Assert.Equal("Second question", body.RootElement.GetProperty("prompt").GetString());
            return new HttpResponseMessage(HttpStatusCode.Accepted);
        });
        using var client = new HttpClient(handler) { BaseAddress = new Uri("http://fixture.invalid") };
        var invoker = new NodeInvoker("fixture-token", client);
        var snapshot = new DesktopContextSnapshot { Id = "ctx-fixture", CapturedAt = DateTimeOffset.UtcNow, Cursor = new Point2D(0, 0) };
        Assert.Equal("inv-fixture", await invoker.SendInvocationAsync(snapshot, "First question"));
        Assert.True(await invoker.SendFollowupAsync("inv-fixture", "Second question"));
        Assert.Equal(new[] { "/invoke", "/invocations/inv-fixture/followup" }, paths);
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
        var status = await new NodeInvoker("fixture-token", client).PollUntilTerminalAsync("inv-fixture");
        Assert.True(status.IsTerminal);
        Assert.Equal(expected, status.FollowupAvailable);
    }
}
