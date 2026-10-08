using WindowsHarness.Host.Http;

namespace WindowsHarness.Host.Tests;

public sealed class LocalAuthenticationTests
{
    [Fact]
    public void SupervisedTokenIsSharedAndRandomUnlessExplicitlyConfigured()
    {
        Assert.Equal("shared", LocalAuthentication.SessionToken("shared", true, false));
        var first = LocalAuthentication.SessionToken(null, true, false);
        Assert.Equal(64, first.Length);
        Assert.NotEqual(first, LocalAuthentication.SessionToken(null, true, false));
    }

    [Fact]
    public void SplitDevelopmentRequiresExplicitConsentOrToken()
    {
        Assert.Throws<InvalidOperationException>(() => LocalAuthentication.SessionToken(null, false, false));
        Assert.Equal("", LocalAuthentication.SessionToken(null, false, true));
        Assert.Equal("shared", LocalAuthentication.SessionToken("shared", false, false));
    }

    [Fact]
    public void MissingWrongAndEmptyTokensFailClosed()
    {
        Assert.False(LocalAuthentication.Authorized(null, "shared", false));
        Assert.False(LocalAuthentication.Authorized("wrong", "shared", false));
        Assert.False(LocalAuthentication.Authorized("", "", false));
        Assert.True(LocalAuthentication.Authorized("shared", "shared", false));
        Assert.True(LocalAuthentication.Authorized(null, "", true));
        Assert.False(LocalAuthentication.Authorized("wrong", "shared", true));
    }
}
