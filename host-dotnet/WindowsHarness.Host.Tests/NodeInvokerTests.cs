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
    public async Task ModelCatalogExposesImageSupport(string supported, bool expected)
    {
        using var handler = new FixtureHandler(_ => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent($"{{\"models\":[{{\"provider\":\"fixture\",\"id\":\"model\",\"name\":\"Fixture\",\"reasoning\":false,\"thinkingLevels\":[\"off\"],\"supportsImages\":{supported}}}],\"current\":null}}", Encoding.UTF8, "application/json"),
        }));
        using var client = new HttpClient(handler) { BaseAddress = new Uri("http://fixture.invalid") };
        var catalog = await new NodeInvoker("fixture-token", client).GetModelsAsync();
        Assert.NotNull(catalog);
        Assert.Equal(expected, Assert.Single(catalog.Models).SupportsImages);
    }

    [Fact]
    public async Task HealthCheckReturnsTrueOnceHarnessListens()
    {
        using var handler = new FixtureHandler(_ => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent("{}", Encoding.UTF8, "application/json"),
        }));
        using var client = new HttpClient(handler) { BaseAddress = new Uri("http://fixture.invalid") };
        Assert.True(await new NodeInvoker("fixture-token", client).CheckHealthAsync());
    }

    [Fact]
    public async Task HealthCheckReturnsFalseWhileHarnessIsStarting()
    {
        using var handler = new FixtureHandler(_ => Task.FromException<HttpResponseMessage>(new HttpRequestException("connection refused")));
        using var client = new HttpClient(handler) { BaseAddress = new Uri("http://fixture.invalid") };
        Assert.False(await new NodeInvoker("fixture-token", client).CheckHealthAsync());
    }

    [Theory]
    [InlineData(HttpStatusCode.Unauthorized, false)]
    [InlineData(HttpStatusCode.Forbidden, false)]
    [InlineData(HttpStatusCode.NotFound, false)]
    [InlineData(HttpStatusCode.RequestTimeout, true)]
    [InlineData(HttpStatusCode.TooManyRequests, true)]
    [InlineData(HttpStatusCode.InternalServerError, true)]
    [InlineData(HttpStatusCode.ServiceUnavailable, true)]
    public async Task CatalogClassifiesHttpFailures(HttpStatusCode status, bool canRetry)
    {
        using var handler = new FixtureHandler(_ => Task.FromResult(new HttpResponseMessage(status)));
        using var client = new HttpClient(handler) { BaseAddress = new Uri("http://fixture.invalid") };
        var result = await new NodeInvoker("fixture-token", client).GetModelCatalogAsync();
        Assert.Null(result.Catalog);
        Assert.NotNull(result.Error);
        Assert.Equal(canRetry, result.CanRetry);
    }

    [Theory]
    [InlineData("not json")]
    [InlineData("null")]
    [InlineData("{}")]
    [InlineData("{\"models\":null}")]
    public async Task InvalidCatalogIsNotRetryable(string body)
    {
        using var handler = new FixtureHandler(_ => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent(body, Encoding.UTF8, "application/json"),
        }));
        using var client = new HttpClient(handler) { BaseAddress = new Uri("http://fixture.invalid") };
        var result = await new NodeInvoker("fixture-token", client).GetModelCatalogAsync();
        Assert.Null(result.Catalog);
        Assert.NotNull(result.Error);
        Assert.False(result.CanRetry);
    }

    [Fact]
    public async Task CatalogTransportFailureIsRetryable()
    {
        using var handler = new FixtureHandler(_ => Task.FromException<HttpResponseMessage>(new HttpRequestException("connection refused")));
        using var client = new HttpClient(handler) { BaseAddress = new Uri("http://fixture.invalid") };
        Assert.True((await new NodeInvoker("fixture-token", client).GetModelCatalogAsync()).CanRetry);
    }

    private sealed class WaitingHandler : HttpMessageHandler
    {
        public TaskCompletionSource Started { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Started.SetResult();
            await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
            return new HttpResponseMessage(HttpStatusCode.OK);
        }
    }

    [Fact]
    public async Task ClientTimeoutRemainsRetryable()
    {
        using var handler = new WaitingHandler();
        using var client = new HttpClient(handler)
        {
            BaseAddress = new Uri("http://fixture.invalid"),
            Timeout = TimeSpan.FromMilliseconds(20),
        };
        var invoker = new NodeInvoker("fixture-token", client);
        Assert.True((await invoker.GetModelCatalogAsync().WaitAsync(TimeSpan.FromSeconds(5))).CanRetry);
    }

    [Fact]
    public async Task CatalogCanSucceedAfterTemporaryBootstrapFailure()
    {
        var attempts = 0;
        using var handler = new FixtureHandler(_ => Task.FromResult(++attempts == 1
            ? new HttpResponseMessage(HttpStatusCode.ServiceUnavailable)
            : new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent("{\"models\":[{\"provider\":\"fixture\",\"id\":\"model\",\"name\":\"Fixture\",\"reasoning\":false,\"thinkingLevels\":[\"off\"]}],\"current\":{\"provider\":\"fixture\",\"modelId\":\"model\",\"thinkingLevel\":\"off\"}}", Encoding.UTF8, "application/json"),
            }));
        using var client = new HttpClient(handler) { BaseAddress = new Uri("http://fixture.invalid") };
        var invoker = new NodeInvoker("fixture-token", client);
        Assert.True((await invoker.GetModelCatalogAsync()).CanRetry);
        var result = await invoker.GetModelCatalogAsync();
        Assert.NotNull(result.Catalog);
        Assert.Equal("fixture", Assert.Single(result.Catalog.Models).Provider);
        Assert.Equal("model", result.Catalog.Current?.ModelId);
    }

    [Theory]
    [InlineData(true, true)]
    [InlineData(true, false)]
    [InlineData(false, true)]
    [InlineData(false, false)]
    public async Task LinkedCancellationInterruptsPendingRequests(bool health, bool deadline)
    {
        using var handler = new WaitingHandler();
        using var client = new HttpClient(handler) { BaseAddress = new Uri("http://fixture.invalid") };
        using var windowClosed = new CancellationTokenSource();
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(windowClosed.Token);
        var invoker = new NodeInvoker("fixture-token", client);
        Task pending = health ? invoker.CheckHealthAsync(budget.Token) : invoker.GetModelCatalogAsync(budget.Token);
        await handler.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        if (deadline) budget.CancelAfter(TimeSpan.FromMilliseconds(20));
        else windowClosed.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => pending.WaitAsync(TimeSpan.FromSeconds(5)));
        Assert.Equal(!deadline, windowClosed.IsCancellationRequested);
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
