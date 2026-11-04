
TEST_F(HistoryTabHelperTest, NativeOwnerRetainsDocumentTokenAndCreatesDistinctSameDocumentEventIDs) {
  NativeHistoryOwner::InstallProvider(base::BindRepeating(
      [](content::WebContents*, const std::string& logical, int owner) {
        return logical == "native-owned-tab" && owner == 1;
      }), {});
  base::ScopedClosureRunner restore_provider(base::BindOnce([] {
    NativeHistoryOwner::InstallProvider(base::BindRepeating(
        [](content::WebContents*, const std::string&, int) { return false; }), {});
  }));
  ASSERT_TRUE(NativeHistoryOwner::RegisterOwned(web_contents(), "native-owned-tab", 1, false));
  NavigateAndCommit(GURL("https://native-owner.example/document"));
  auto* owner = NativeHistoryOwner::FromWebContents(web_contents()); ASSERT_TRUE(owner);
  const auto initial = owner->Describe(); ASSERT_TRUE(initial); ASSERT_FALSE(initial->current_event_id.empty());
  auto push = content::NavigationSimulator::CreateRendererInitiated(
      GURL("https://native-owner.example/document#push"), web_contents()->GetPrimaryMainFrame());
  push->CommitSameDocument();
  const auto pushed = owner->Describe(); ASSERT_TRUE(pushed);
  EXPECT_EQ(initial->document_token, pushed->document_token);
  EXPECT_NE(initial->current_event_id, pushed->current_event_id);
  ASSERT_FALSE(pushed->current_event_id.empty());
  auto back = content::NavigationSimulator::CreateHistoryNavigation(-1, web_contents(), false);
  back->CommitSameDocument();
  const auto backed = owner->Describe(); ASSERT_TRUE(backed);
  EXPECT_EQ(initial->document_token, backed->document_token);
  EXPECT_NE(initial->current_event_id, backed->current_event_id);
  EXPECT_NE(pushed->current_event_id, backed->current_event_id);
  auto forward = content::NavigationSimulator::CreateHistoryNavigation(1, web_contents(), false);
  forward->CommitSameDocument();
  const auto forwarded = owner->Describe(); ASSERT_TRUE(forwarded);
  EXPECT_EQ(initial->document_token, forwarded->document_token);
  EXPECT_NE(backed->current_event_id, forwarded->current_event_id);
  EXPECT_EQ("native-owned-tab", forwarded->logical_id);
}
