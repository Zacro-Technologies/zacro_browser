// Native host tab identity reservations retain Chromium's unique ID allocator.
#include "components/sessions/content/session_tab_helper.h"

#include "base/functional/bind.h"
#include "base/test/bind.h"
#include "content/public/browser/web_contents.h"
#include "content/public/test/browser_task_environment.h"
#include "content/public/test/test_browser_context.h"
#include "content/public/test/web_contents_tester.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace sessions {
namespace {
class NativeSessionTabHelperTest : public testing::Test {
 protected:
  void TearDown() override {
    SessionTabHelper::SetNativeInitialIDProvider({});
  }

  std::unique_ptr<content::WebContents> NewContents() {
    return content::WebContentsTester::CreateTestWebContents(&context_, nullptr);
  }

  void Attach(content::WebContents* contents) {
    SessionTabHelper::CreateForWebContents(contents, base::BindRepeating(
        [](content::WebContents*) -> SessionTabHelperDelegate* { return nullptr; }));
  }

  content::BrowserTaskEnvironment environment_;
  content::TestBrowserContext context_;
};

TEST_F(NativeSessionTabHelperTest, ReservedIdentityBelongsOnlyToMatchingContents) {
  const auto reserved = SessionID::NewUnique();
  auto target = NewContents();
  auto unrelated = NewContents();
  int reservations_used = 0;
  SessionTabHelper::SetNativeInitialIDProvider(base::BindLambdaForTesting(
      [&](content::WebContents* contents) -> std::optional<SessionID> {
        if (contents != target.get()) return std::nullopt;
        ++reservations_used;
        return reserved;
      }));
  Attach(unrelated.get());
  Attach(target.get());
  EXPECT_EQ(SessionTabHelper::IdForTab(target.get()), reserved);
  EXPECT_TRUE(SessionTabHelper::IdForTab(unrelated.get()).is_valid());
  EXPECT_NE(SessionTabHelper::IdForTab(unrelated.get()), reserved);
  // Reattaching helpers must not consume a second token or change tab identity.
  Attach(target.get());
  EXPECT_EQ(reservations_used, 1);
  EXPECT_EQ(SessionTabHelper::IdForTab(target.get()), reserved);
}

TEST_F(NativeSessionTabHelperTest, MissingReservationPreservesNormalUniqueIDs) {
  SessionTabHelper::SetNativeInitialIDProvider(base::BindRepeating(
      [](content::WebContents*) -> std::optional<SessionID> { return std::nullopt; }));
  auto first = NewContents();
  auto second = NewContents();
  Attach(first.get());
  SessionTabHelper::SetNativeInitialIDProvider({});
  Attach(second.get());
  EXPECT_TRUE(SessionTabHelper::IdForTab(first.get()).is_valid());
  EXPECT_TRUE(SessionTabHelper::IdForTab(second.get()).is_valid());
  EXPECT_NE(SessionTabHelper::IdForTab(first.get()), SessionTabHelper::IdForTab(second.get()));
}
}  // namespace
}  // namespace sessions
