// Browser-owned presentation is independent of extension JS subscriptions.
IN_PROC_BROWSER_TEST_F(SidePanelApiTest, NativePresentationWithoutJSListeners) {
  class PresentationObserver : public SidePanelService::Observer {
   public:
    void OnPanelOptionsChanged(const ExtensionId&,
        const api::side_panel::PanelOptions&) override {}
    void OnSidePanelServiceShutdown() override {}
    void OnNativePanelPresentationChanged(const ExtensionId& extension_id,
        int window_id, std::optional<int> tab_id, bool visible) override {
      EXPECT_EQ(extension_id, std::string(32, 'a'));
      EXPECT_EQ(window_id, 47);
      EXPECT_EQ(tab_id, expected_tab);
      EXPECT_EQ(visible, expected_visible);
      ++calls;
    }
    int calls = 0;
    bool expected_visible = true;
    std::optional<int> expected_tab;
  } observer;
  auto* service = SidePanelService::Get(profile());
  const std::string extension_id(32, 'a');
  ASSERT_FALSE(EventRouter::Get(profile())->ExtensionHasEventListener(extension_id, "sidePanel.onOpened"));
  ASSERT_FALSE(EventRouter::Get(profile())->ExtensionHasEventListener(extension_id, "sidePanel.onClosed"));
  service->AddObserver(&observer);
  service->DispatchOnOpenedEvent(extension_id, 47, std::nullopt, "panel.html");
  observer.expected_visible = false;
  service->DispatchOnClosedEvent(extension_id, 47, std::nullopt, "panel.html");
  observer.expected_tab = 83;
  observer.expected_visible = true;
  service->DispatchOnOpenedEvent(extension_id, 47, 83, "contextual.html");
  observer.expected_visible = false;
  service->DispatchOnClosedEvent(extension_id, 47, 83, "contextual.html");
  EXPECT_EQ(observer.calls, 4);
  service->RemoveObserver(&observer);
  service->DispatchOnOpenedEvent(extension_id, 47, std::nullopt, "panel.html");
  EXPECT_EQ(observer.calls, 4);
}
