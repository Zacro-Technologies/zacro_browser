#if BUILDFLAG(IS_MAC)
// These fixtures only select dummy files under an isolated temporary home.
// They never start a host process or read an installed user's registration.
class NativeMessagingManifestPathsTest : public testing::Test {
 protected:
  void SetUp() override {
    ASSERT_TRUE(directory_.CreateUniqueTempDir());
    configured_user_ = directory_.GetPath().Append("configured-user");
    configured_system_ = directory_.GetPath().Append("configured-system");
    home_ = directory_.GetPath().Append("home");
    ASSERT_TRUE(base::CreateDirectory(configured_user_));
    ASSERT_TRUE(base::CreateDirectory(configured_system_));
    ASSERT_TRUE(base::CreateDirectory(home_));
    user_override_ = std::make_unique<base::ScopedPathOverride>(
        chrome::DIR_USER_NATIVE_MESSAGING, configured_user_);
    system_override_ = std::make_unique<base::ScopedPathOverride>(
        chrome::DIR_NATIVE_MESSAGING, configured_system_);
    home_override_ = std::make_unique<base::ScopedPathOverride>(base::DIR_HOME, home_);
  }
  base::FilePath Write(const base::FilePath& directory) {
    EXPECT_TRUE(base::CreateDirectory(directory));
    auto path = directory.Append(host_ + ".json");
    // Intentionally invalid: selection must not skip an existing bad manifest.
    EXPECT_TRUE(base::WriteFile(path, "not a manifest"));
    return path;
  }
  base::FilePath UserChromium() const {
    return home_.Append("Library/Application Support/Chromium/NativeMessagingHosts");
  }
  base::FilePath UserChrome() const {
    return home_.Append("Library/Application Support/Google/Chrome/NativeMessagingHosts");
  }
  base::FilePath Find(bool user_allowed) {
    std::string error;
    return LaunchContext::FindManifest(host_, user_allowed, error);
  }
  // Random host identity ensures a test cannot match a real system host.
  const std::string host_ = "com.zacro.fixture_" + base::NumberToString(base::RandUint64());
  base::ScopedTempDir directory_;
  base::FilePath configured_user_, configured_system_, home_;
  std::unique_ptr<base::ScopedPathOverride> user_override_, system_override_, home_override_;
};

TEST_F(NativeMessagingManifestPathsTest, ConfiguredUserPrecedesVendorFallbacks) {
  Write(UserChrome()); Write(UserChromium()); Write(configured_system_);
  auto configured = Write(configured_user_);
  EXPECT_EQ(configured, Find(true));
}

TEST_F(NativeMessagingManifestPathsTest, ChromiumUserPrecedesChromeUser) {
  Write(UserChrome()); Write(configured_system_);
  auto chromium = Write(UserChromium());
  EXPECT_EQ(chromium, Find(true));
}

TEST_F(NativeMessagingManifestPathsTest, ChromeUserPrecedesSystem) {
  Write(configured_system_);
  auto chrome = Write(UserChrome());
  EXPECT_EQ(chrome, Find(true));
}

TEST_F(NativeMessagingManifestPathsTest, DisabledUserPolicySkipsEveryUserPath) {
  Write(configured_user_); Write(UserChromium()); Write(UserChrome());
  auto system = Write(configured_system_);
  EXPECT_EQ(system, Find(false));
}

TEST_F(NativeMessagingManifestPathsTest, MissingHostDoesNotInventRegistration) {
  EXPECT_TRUE(Find(true).empty());
  EXPECT_TRUE(Find(false).empty());
}
#endif
